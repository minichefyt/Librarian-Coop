"""LibrarianCoop relay: carries player state between two PCs over UDP.

The game mod writes <netdir>/me.state ("seq x y z yaw pitch"). This relay sends it to the
other player and writes what it receives to <netdir>/peer.state, which the mod reads.

Host:   python coop_relay.py --netdir <dir> --listen 7788
Client: python coop_relay.py --netdir <dir> --connect <host ip>:7788

Over Radmin VPN, <host ip> is the host's Radmin address (26.x.x.x). Standard library only.
"""

import argparse
import os
import random
import re
import socket
import time

MAGIC = b"LCOOP1 "     # position, unreliable, latest wins
EV_MAGIC = b"LCEV1 "   # book event, reliable, in order: "LCEV1 <seq> <payload>"
ACK_MAGIC = b"LCACK1 " # cumulative ack: "LCACK1 <highest seq delivered in order>"
TICK = 0.05          # 20 Hz
KEEPALIVE = 1.0      # resend even without changes, so the host learns the client address
RESEND = 0.2         # resend unacknowledged events this often
MAX_PACKET = 256

UID = r"[0-9A-F]{32}"
NUM = r"-?\d{1,7}(?:\.\d{1,3})?"
SHELF = r"%s@-?\d{1,7}@-?\d{1,7}" % UID
EVENT_RE = re.compile(
    r"^(grab {u}|insert {u} {s} \d{{1,4}}|place {u}(?: {n}){{6}}|tp"
    r"|syncreq|snapbegin \d{{1,5}}|snapend|sshelf {u} {s} \d{{1,4}}|sfloor {u}(?: {n}){{6}}|shost {u})$".format(
        u=UID, s=SHELF, n=NUM))
WINDOW = 256         # unacknowledged events in flight at once (a library snapshot is ~3000 events)
SESS_RE = re.compile(r"^[0-9a-f]{8}$")


def parse_event(text):
    """'<seq> <payload>' -> (seq, payload) if the payload is a known, well-formed book event."""
    parts = text.strip().split(" ", 1)
    if len(parts) != 2 or not parts[0].isdigit():
        return None
    if not EVENT_RE.match(parts[1]):
        return None
    return int(parts[0]), parts[1]


class EventReader:
    """Reads complete new lines that the mod appends to events.out."""

    def __init__(self, path):
        self.path = path
        # start at the end: what happened before this relay ran is covered by the library snapshot
        try:
            self.offset = os.path.getsize(path)
        except OSError:
            self.offset = 0
        self.seq = 0   # the relay numbers events itself, so a rejected line never leaves a gap

    def skip(self):
        """Drop everything written so far (used while no friend is connected)."""
        try:
            self.offset = os.path.getsize(self.path)
        except OSError:
            pass

    def new_events(self):
        try:
            if os.path.getsize(self.path) < self.offset:
                self.offset = 0   # the game started a new session and emptied the file
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read()
        except OSError:
            return []
        if len(data) == 0:
            return []
        end = data.rfind(b"\n")
        if end < 0:
            return []
        self.offset += end + 1
        events = []
        for raw in data[:end].split(b"\n"):
            ev = parse_event(raw.decode("ascii", "replace"))
            if ev:
                self.seq += 1
                events.append((self.seq, ev[1]))
            elif raw.strip():
                print("dropped malformed local event: %r" % raw[:80], flush=True)
        return events


def parse_state(line):
    """Return the normalised state line, or None if it is not 'int float float float float float'."""
    parts = line.split()
    if len(parts) != 6:
        return None
    try:
        seq = int(parts[0])
        nums = [float(p) for p in parts[1:]]
    except ValueError:
        return None
    if seq < 0 or any(abs(n) > 1e7 for n in nums):
        return None
    return "%d %s\n" % (seq, " ".join("%.2f" % n for n in nums))


def read_me(path):
    try:
        with open(path, "r", encoding="ascii") as f:
            return parse_state(f.readline())
    except (OSError, UnicodeDecodeError):
        return None


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii") as f:
        f.write(text)
    for _ in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:   # the game may be reading the file this instant
            time.sleep(0.005)


NAME_MAGIC = b"LCNAME1 "   # player name, sent every few seconds
COLOR_MAGIC = b"LCCOL1 "   # bean colour "r g b" (0-255), sent with the name
NAME_EVERY = 2.0
NAME_RE = re.compile(r"^[A-Za-z0-9 _\-]{1,16}$")
COLOR_RE = re.compile(r"^(\d{1,3}) (\d{1,3}) (\d{1,3})$")


def clean_color(color):
    """'r g b' with each 0-255, or the default blue."""
    m = COLOR_RE.match((color or "").strip())
    if m and all(int(v) <= 255 for v in m.groups()):
        return "%d %d %d" % tuple(int(v) for v in m.groups())
    return "64 140 255"


def clean_name(name):
    name = re.sub(r"[^A-Za-z0-9 _\-]", "", name or "").strip()[:16]
    return name or "Player"


def run(netdir, listen=None, connect=None, name="Player", seconds=0, stop=None, on_status=None, color=None):
    """Run the relay until `stop` (a threading.Event) is set, or for `seconds` if given.

    listen=<port> for the host, connect="<ip>:<port>" for the joining player.
    on_status(dict) is called about once a second (the launcher shows it).
    """
    os.makedirs(netdir, exist_ok=True)
    me_path = os.path.join(netdir, "me.state")
    peer_path = os.path.join(netdir, "peer.state")
    status_path = os.path.join(netdir, "relay.status")
    peername_path = os.path.join(netdir, "peername.txt")
    my_name = clean_name(name)
    write_atomic(os.path.join(netdir, "myname.txt"), my_name + "\n")
    color_path = os.path.join(netdir, "mycolor.txt")
    if color is not None:
        write_atomic(color_path, clean_color(color) + "\n")
    peercolor_path = os.path.join(netdir, "peercolor.txt")
    peer_color = None

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if listen:
        sock.bind(("0.0.0.0", int(listen)))
        peer = None
        role = "host"
    else:
        host, port = connect.rsplit(":", 1)
        peer = (host.strip(), int(port))
        sock.bind(("0.0.0.0", 0))
        role = "client"
    sock.settimeout(TICK)
    # the mod reads this: the host wins when both players grab the same book
    write_atomic(os.path.join(netdir, "role.txt"), role + "\n")

    print("relay %s up, netdir=%s, %s" % (role, netdir,
          "listening on %d" % int(listen) if listen else "sending to %s:%d" % peer), flush=True)

    events_in_path = os.path.join(netdir, "events.in")
    reader = EventReader(os.path.join(netdir, "events.out"))
    # Sessions: each relay run has its own id, carried on events, acks and name messages. When the other side's
    # id is new (first contact) or changes (their relay restarted), numbering restarts on both directions and
    # the mod is told with a "0 reset" line, so it forgets its old count (and a joiner asks for the library).
    my_sess = "%08x" % random.getrandbits(32)
    peer_sess = None
    last_name_send = 0.0
    peer_name = None
    unacked = {}          # seq -> payload, our events not yet confirmed by the peer
    last_resend = 0.0
    delivered = 0         # highest peer event seq written to events.in, in order
    pending = {}          # peer events that arrived ahead of a gap
    ev_sent = ev_recv = ev_dup = 0

    def deliver(payload_seq, payload):
        with open(events_in_path, "a", encoding="ascii") as f:
            f.write("%d %s\n" % (payload_seq, payload))

    sent = recv = rejected = 0
    last_line = None
    last_send = 0.0
    last_recv = 0.0
    last_status = 0.0
    start = time.time()

    while True:
        now = time.time()
        if seconds and now - start > seconds:
            break
        if stop is not None and stop.is_set():
            break

        # receive everything that is waiting
        try:
            while True:
                data, addr = sock.recvfrom(MAX_PACKET)
                sess = None
                if data.startswith(MAGIC):
                    sess, _, text = data[len(MAGIC):].decode("ascii", "replace").partition(" ")
                    line = parse_state(text) if SESS_RE.match(sess) else None
                    kind = "state"
                elif data.startswith(EV_MAGIC):
                    sess, _, text = data[len(EV_MAGIC):].decode("ascii", "replace").partition(" ")
                    line = parse_event(text) if SESS_RE.match(sess) else None
                    kind = "event"
                elif data.startswith(ACK_MAGIC):
                    sess, _, text = data[len(ACK_MAGIC):].decode("ascii", "replace").strip().partition(" ")
                    line = int(text) if SESS_RE.match(sess) and text.isdigit() else None
                    kind = "ack"
                elif data.startswith(NAME_MAGIC):
                    sess, _, text = data[len(NAME_MAGIC):].decode("ascii", "replace").strip().partition(" ")
                    line = text if SESS_RE.match(sess) and NAME_RE.match(text) else None
                    kind = "name"
                elif data.startswith(COLOR_MAGIC):
                    text = data[len(COLOR_MAGIC):].decode("ascii", "replace").strip()
                    line = clean_color(text) if COLOR_RE.match(text) else None
                    kind = "color"
                else:
                    line, kind = None, None
                if line is None:
                    rejected += 1
                    continue
                if role == "host" and peer != addr:
                    print("peer is now %s:%d" % addr, flush=True)
                    peer = addr
                recv += 1
                last_recv = time.time()
                if sess is not None and kind != "ack" and sess != peer_sess:
                    # the other relay is new or restarted: restart numbering both ways, tell the mod.
                    # (positions carry the session too, so this happens on the very first packet, before
                    #  the mod sees the friend and sends anything)
                    print("peer session %s -> %s: restarting event numbering" % (peer_sess, sess), flush=True)
                    peer_sess = sess
                    delivered = 0
                    pending.clear()
                    waiting = [unacked[s] for s in sorted(unacked)]
                    unacked.clear()
                    for i, payload in enumerate(waiting, 1):
                        unacked[i] = payload
                    reader.seq = len(waiting)
                    with open(events_in_path, "a", encoding="ascii") as f:
                        f.write("0 reset\n")
                if kind == "state":
                    write_atomic(peer_path, line)
                elif kind == "name":
                    if line != peer_name:
                        peer_name = line
                        write_atomic(peername_path, line + "\n")
                elif kind == "color":
                    if line != peer_color:
                        peer_color = line
                        write_atomic(peercolor_path, line + "\n")
                elif kind == "ack":
                    if sess != my_sess:
                        continue   # an ack for a previous run of this relay
                    acked = [s for s in unacked if s <= line]
                    for s in acked:
                        del unacked[s]
                    if acked:
                        last_resend = 0.0   # window moved: send the next events right away
                elif kind == "event":
                    ev_recv += 1
                    eseq, payload = line
                    if eseq <= delivered:
                        ev_dup += 1
                    else:
                        pending[eseq] = payload
                        while delivered + 1 in pending:
                            delivered += 1
                            deliver(delivered, pending.pop(delivered))
                    sock.sendto(ACK_MAGIC + ("%s %d" % (peer_sess, delivered)).encode("ascii"), addr)
        except socket.timeout:
            pass
        except ConnectionResetError:   # Windows reports ICMP port-unreachable this way; peer not up yet
            pass

        # our book events: queue new ones, (re)send the oldest unacknowledged window.
        # Until the friend has been heard from, drop them: the joiner gets a library snapshot instead, and a
        # joiner's solo play from before connecting must not be replayed on the host.
        if peer_sess is None:
            reader.skip()
        else:
            for eseq, payload in reader.new_events():
                unacked[eseq] = payload
                last_resend = 0.0
        if peer and unacked and time.time() - last_resend > RESEND:
            for eseq in sorted(unacked)[:WINDOW]:
                try:
                    sock.sendto(EV_MAGIC + ("%s %d %s" % (my_sess, eseq, unacked[eseq])).encode("ascii"), peer)
                    ev_sent += 1
                except OSError:
                    pass
            last_resend = time.time()

        # send our state when it changed, or as keepalive
        line = read_me(me_path)
        now = time.time()
        if peer and line and (line != last_line or now - last_send > KEEPALIVE):
            try:
                sock.sendto(MAGIC + ("%s %s" % (my_sess, line)).encode("ascii"), peer)
                sent += 1
                last_send = now
                last_line = line
            except OSError:
                pass

        if peer and now - last_name_send > NAME_EVERY:
            try:
                sock.sendto(NAME_MAGIC + ("%s %s" % (my_sess, my_name)).encode("ascii"), peer)
                # read every time, so a colour picked in the launcher while connected goes out within 2 s
                try:
                    with open(color_path, "r", encoding="ascii") as f:
                        my_color = clean_color(f.readline())
                except OSError:
                    my_color = clean_color(None)
                sock.sendto(COLOR_MAGIC + my_color.encode("ascii"), peer)
                last_name_send = now
            except OSError:
                pass

        if now - last_status > 1.0:
            last_status = now
            status = {
                "role": role, "peer": "%s:%d" % peer if peer else "none", "peer_name": peer_name or "",
                "peer_color": peer_color or "",
                "sent": sent, "recv": recv, "rejected": rejected,
                "last_recv_age": (now - last_recv) if last_recv else None,
                "events_out": reader.seq,
                "events_sent": ev_sent, "events_unacked": len(unacked), "events_recv": ev_recv,
                "events_delivered": delivered, "events_dup": ev_dup,
            }
            write_atomic(status_path, "".join("%s=%s\n" % (k, "never" if v is None else
                                                          ("%.1f" % v if isinstance(v, float) else v))
                                              for k, v in status.items()))
            if on_status:
                on_status(status)

    sock.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--netdir", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--listen", type=int, metavar="PORT")
    g.add_argument("--connect", metavar="IP:PORT")
    ap.add_argument("--name", default="Player")
    ap.add_argument("--color", default=None, help='bean colour "r g b", 0-255')
    ap.add_argument("--seconds", type=float, default=0, help="stop after N seconds (tests)")
    args = ap.parse_args()
    run(args.netdir, listen=args.listen, connect=args.connect, name=args.name, seconds=args.seconds,
        color=args.color)


if __name__ == "__main__":
    main()
