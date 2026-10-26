// LibrarianCoop launcher + relay for "Librarian: Tidy Up the Arcane Library!" co-op.
// One exe, .NET Framework 4.8 (built into Windows 10/11), no installs.
//
// Put LibrarianCoop.exe in the game folder (next to Librarian.exe). It talks to the LibrarianCoop UE4SS mod through
// files in Librarian\Binaries\Win64\ue4ss\Mods\LibrarianCoop\net and to the friend's launcher over UDP (default 7788).
// Over Radmin VPN the host shares their 26.x.x.x address; the friend picks Join and types it in.
//
// Protocol (same as coop_relay.py, see its docstring): positions "LCOOP1 <sess> <state>" (unreliable), reliable
// ordered events "LCEV1 <sess> <seq> <payload>" with cumulative acks "LCACK1 <sess> <n>", "LCNAME1 <sess> <name>",
// "LCCOL1 r g b". Sessions restart numbering when the other launcher restarts ("0 reset" line for the mod).
//
// Command line: --netdir <dir>  --autostart  --no-backup
//               --relay (no window) with --listen <port> | --connect <ip:port>  [--name n] [--color "r g b"] [--seconds s]
//
// Build: C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /out:LibrarianCoop.exe LibrarianCoop.cs

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace LibrarianCoop
{
    static class Files
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool MoveFileEx(string existing, string target, int flags);
        const int MOVEFILE_REPLACE_EXISTING = 1;

        // write to a temp file, then replace: the mod never reads half a file
        public static void WriteAtomic(string path, string text)
        {
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, text, Encoding.ASCII);
            for (int i = 0; i < 5; i++)
            {
                if (MoveFileEx(tmp, path, MOVEFILE_REPLACE_EXISTING)) return;
                Thread.Sleep(5);   // the game may be reading the file this instant
            }
        }

        public static void Append(string path, string text)
        {
            for (int i = 0; i < 5; i++)
            {
                try { File.AppendAllText(path, text, Encoding.ASCII); return; }
                catch (IOException) { Thread.Sleep(5); }
            }
        }

        public static string ReadFirstLine(string path)
        {
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(fs, Encoding.ASCII))
                    return r.ReadLine();
            }
            catch (Exception) { return null; }
        }

        public static Dictionary<string, string> ReadKeyValues(string path)
        {
            var d = new Dictionary<string, string>();
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(fs, Encoding.ASCII))
                {
                    string line;
                    while ((line = r.ReadLine()) != null)
                    {
                        int eq = line.IndexOf('=');
                        if (eq > 0) d[line.Substring(0, eq)] = line.Substring(eq + 1);
                    }
                }
            }
            catch (Exception) { }
            return d;
        }
    }

    static class Proto
    {
        public static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        const string UID = "[0-9A-F]{32}";
        const string NUM = @"-?\d{1,7}(?:\.\d{1,3})?";
        static readonly string SHELF = UID + @"@-?\d{1,7}@-?\d{1,7}";
        public static readonly Regex EventRe = new Regex(
            "^(grab " + UID + "|insert " + UID + " " + SHELF + @" \d{1,4}|place " + UID + "(?: " + NUM + "){6}|tp" +
            "|syncreq|snapbegin \\d{1,5}|snapend|sshelf " + UID + " " + SHELF + @" \d{1,4}|sfloor " + UID + "(?: " + NUM + "){6}|shost " + UID + ")$");
        public static readonly Regex SessRe = new Regex("^[0-9a-f]{8}$");
        public static readonly Regex NameRe = new Regex(@"^[A-Za-z0-9 _\-]{1,16}$");
        public static readonly Regex ColorRe = new Regex(@"^(\d{1,3}) (\d{1,3}) (\d{1,3})$");

        // "seq x y z yaw pitch" -> normalised, or null
        public static string ParseState(string line)
        {
            if (line == null) return null;
            var p = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (p.Length != 6) return null;
            long seq;
            if (!long.TryParse(p[0], NumberStyles.Integer, Inv, out seq) || seq < 0) return null;
            var sb = new StringBuilder(seq.ToString(Inv));
            for (int i = 1; i < 6; i++)
            {
                double v;
                if (!double.TryParse(p[i], NumberStyles.Float, Inv, out v) || Math.Abs(v) > 1e7 || double.IsNaN(v)) return null;
                sb.Append(' ').Append(v.ToString("F2", Inv));
            }
            return sb.Append('\n').ToString();
        }

        // "<seq> <payload>" -> payload if it is a known, well-formed event
        public static string ParseEventPayload(string text)
        {
            text = text.Trim();
            int sp = text.IndexOf(' ');
            if (sp <= 0) return null;
            string seq = text.Substring(0, sp), payload = text.Substring(sp + 1);
            if (!seq.All(char.IsDigit)) return null;
            return EventRe.IsMatch(payload) ? payload : null;
        }

        public static string CleanName(string name)
        {
            name = Regex.Replace(name ?? "", @"[^A-Za-z0-9 _\-]", "").Trim();
            if (name.Length > 16) name = name.Substring(0, 16).Trim();
            return name.Length > 0 ? name : "Player";
        }

        public static string CleanColor(string color)
        {
            var m = ColorRe.Match((color ?? "").Trim());
            if (m.Success)
            {
                int r = int.Parse(m.Groups[1].Value), g = int.Parse(m.Groups[2].Value), b = int.Parse(m.Groups[3].Value);
                if (r <= 255 && g <= 255 && b <= 255) return r + " " + g + " " + b;
            }
            return "64 140 255";
        }
    }

    // Reads complete new lines the mod appends to events.out. Starts at the end: what happened before this relay ran
    // is covered by the library snapshot. The relay numbers events itself, so a rejected line never leaves a gap.
    class EventReader
    {
        readonly string path;
        long offset;
        public int Seq;

        public EventReader(string path)
        {
            this.path = path;
            Skip();
        }

        public void Skip()
        {
            try { offset = new FileInfo(path).Length; } catch (Exception) { offset = 0; }
        }

        public List<KeyValuePair<int, string>> NewEvents()
        {
            var list = new List<KeyValuePair<int, string>>();
            try
            {
                var fi = new FileInfo(path);
                if (!fi.Exists) return list;
                if (fi.Length < offset) offset = 0;   // the game started a new session and emptied the file
                byte[] data;
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    fs.Seek(offset, SeekOrigin.Begin);
                    data = new byte[fs.Length - offset];
                    int read = 0;
                    while (read < data.Length)
                    {
                        int n = fs.Read(data, read, data.Length - read);
                        if (n <= 0) break;
                        read += n;
                    }
                    if (read < data.Length) Array.Resize(ref data, read);
                }
                int end = Array.LastIndexOf(data, (byte)'\n');
                if (end < 0) return list;
                offset += end + 1;
                foreach (var raw in Encoding.ASCII.GetString(data, 0, end).Split('\n'))
                {
                    string payload = Proto.ParseEventPayload(raw);
                    if (payload != null) list.Add(new KeyValuePair<int, string>(++Seq, payload));
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return list;
        }
    }

    class Relay
    {
        const double Tick = 0.05, Keepalive = 1.0, Resend = 0.2, NameEvery = 2.0;
        const int Window = 256, MaxPacket = 256;
        static readonly byte[] MAGIC = Encoding.ASCII.GetBytes("LCOOP1 "), EV = Encoding.ASCII.GetBytes("LCEV1 "),
            ACK = Encoding.ASCII.GetBytes("LCACK1 "), NAME = Encoding.ASCII.GetBytes("LCNAME1 "), COL = Encoding.ASCII.GetBytes("LCCOL1 ");

        readonly string netdir, myName;
        readonly int listenPort;
        readonly IPEndPoint connectTo;
        public volatile bool Stop;
        public string Error;
        readonly object statusLock = new object();
        Dictionary<string, string> status = new Dictionary<string, string>();

        public Relay(string netdir, int listenPort, IPEndPoint connectTo, string name, string color)
        {
            this.netdir = netdir;
            this.listenPort = listenPort;
            this.connectTo = connectTo;
            Directory.CreateDirectory(netdir);
            myName = Proto.CleanName(name);
            Files.WriteAtomic(P("myname.txt"), myName + "\n");
            if (color != null) Files.WriteAtomic(P("mycolor.txt"), Proto.CleanColor(color) + "\n");
        }

        string P(string f) { return Path.Combine(netdir, f); }

        public Dictionary<string, string> Status
        {
            get { lock (statusLock) return new Dictionary<string, string>(status); }
        }

        static double Now() { return (DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds; }

        static bool StartsWith(byte[] data, int len, byte[] magic)
        {
            if (len < magic.Length) return false;
            for (int i = 0; i < magic.Length; i++) if (data[i] != magic[i]) return false;
            return true;
        }

        public void Run(double seconds)
        {
            var sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try
            {
                // Windows reports ICMP port-unreachable as a receive error; turn that off (SIO_UDP_CONNRESET)
                try { sock.IOControl(-1744830452, new byte[] { 0 }, null); } catch (Exception) { }
                EndPoint peer = null;
                string role;
                if (listenPort > 0)
                {
                    sock.Bind(new IPEndPoint(IPAddress.Any, listenPort));
                    role = "host";
                }
                else
                {
                    sock.Bind(new IPEndPoint(IPAddress.Any, 0));
                    peer = connectTo;
                    role = "client";
                }
                sock.ReceiveTimeout = (int)(Tick * 1000);
                // the mod reads this: the host wins when both players grab the same book
                Files.WriteAtomic(P("role.txt"), role + "\n");

                var reader = new EventReader(P("events.out"));
                string mySess = new Random().Next().ToString("x8").PadLeft(8, '0').Substring(0, 8);
                string peerSess = null, peerName = null, peerColor = null;
                var unacked = new SortedDictionary<int, string>();
                var pending = new Dictionary<int, string>();
                int delivered = 0;
                long sent = 0, recv = 0, rejected = 0, evSent = 0, evRecv = 0, evDup = 0;
                double lastResend = 0, lastSend = 0, lastRecv = 0, lastStatus = 0, lastNameSend = 0, start = Now();
                string lastLine = null;
                var buf = new byte[MaxPacket + 16];

                while (!Stop)
                {
                    double now = Now();
                    if (seconds > 0 && now - start > seconds) break;

                    // receive everything that is waiting
                    while (true)
                    {
                        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                        int len;
                        try { len = sock.ReceiveFrom(buf, ref from); }
                        catch (SocketException) { break; }   // timeout (or a reset we do not care about)
                        if (len > MaxPacket) { rejected++; continue; }
                        string kind = null, sess = null, line = null;
                        string text;
                        if (StartsWith(buf, len, MAGIC))
                        {
                            kind = "state";
                            text = Encoding.ASCII.GetString(buf, MAGIC.Length, len - MAGIC.Length);
                            Split(text, out sess, out text);
                            if (Proto.SessRe.IsMatch(sess)) line = Proto.ParseState(text);
                        }
                        else if (StartsWith(buf, len, EV))
                        {
                            kind = "event";
                            text = Encoding.ASCII.GetString(buf, EV.Length, len - EV.Length);
                            Split(text, out sess, out text);
                            if (Proto.SessRe.IsMatch(sess)) line = text.Trim();
                        }
                        else if (StartsWith(buf, len, ACK))
                        {
                            kind = "ack";
                            text = Encoding.ASCII.GetString(buf, ACK.Length, len - ACK.Length).Trim();
                            Split(text, out sess, out text);
                            int n;
                            if (Proto.SessRe.IsMatch(sess) && int.TryParse(text, NumberStyles.None, Proto.Inv, out n)) line = text;
                        }
                        else if (StartsWith(buf, len, NAME))
                        {
                            kind = "name";
                            text = Encoding.ASCII.GetString(buf, NAME.Length, len - NAME.Length).Trim();
                            Split(text, out sess, out text);
                            if (Proto.SessRe.IsMatch(sess) && Proto.NameRe.IsMatch(text)) line = text;
                        }
                        else if (StartsWith(buf, len, COL))
                        {
                            kind = "color";
                            text = Encoding.ASCII.GetString(buf, COL.Length, len - COL.Length).Trim();
                            if (Proto.ColorRe.IsMatch(text)) line = Proto.CleanColor(text);
                        }
                        // an event must also be a well-formed book event
                        int evSeq = 0;
                        string evPayload = null;
                        if (kind == "event" && line != null)
                        {
                            int sp = line.IndexOf(' ');
                            evPayload = Proto.ParseEventPayload(line);
                            if (evPayload == null || sp <= 0 || !int.TryParse(line.Substring(0, sp), NumberStyles.None, Proto.Inv, out evSeq))
                                line = null;
                        }
                        if (line == null) { rejected++; continue; }
                        if (role == "host" && !from.Equals(peer)) peer = from;
                        recv++;
                        lastRecv = Now();

                        if (sess != null && kind != "ack" && sess != peerSess)
                        {
                            // the other launcher is new or restarted: restart numbering both ways, tell the mod
                            peerSess = sess;
                            delivered = 0;
                            pending.Clear();
                            var waiting = unacked.Values.ToList();
                            unacked.Clear();
                            for (int i = 0; i < waiting.Count; i++) unacked[i + 1] = waiting[i];
                            reader.Seq = waiting.Count;
                            Files.Append(P("events.in"), "0 reset\n");
                        }

                        if (kind == "state") Files.WriteAtomic(P("peer.state"), line);
                        else if (kind == "name")
                        {
                            if (line != peerName) { peerName = line; Files.WriteAtomic(P("peername.txt"), line + "\n"); }
                        }
                        else if (kind == "color")
                        {
                            if (line != peerColor) { peerColor = line; Files.WriteAtomic(P("peercolor.txt"), line + "\n"); }
                        }
                        else if (kind == "ack")
                        {
                            if (sess != mySess) continue;   // an ack for a previous run of this launcher
                            int n = int.Parse(line, Proto.Inv);
                            var acked = unacked.Keys.Where(s => s <= n).ToList();
                            foreach (var s in acked) unacked.Remove(s);
                            if (acked.Count > 0) lastResend = 0;   // window moved: send the next events right away
                        }
                        else if (kind == "event")
                        {
                            evRecv++;
                            if (evSeq <= delivered) evDup++;
                            else
                            {
                                pending[evSeq] = evPayload;
                                var sb = new StringBuilder();
                                while (pending.ContainsKey(delivered + 1))
                                {
                                    delivered++;
                                    sb.Append(delivered.ToString(Proto.Inv)).Append(' ').Append(pending[delivered]).Append('\n');
                                    pending.Remove(delivered);
                                }
                                if (sb.Length > 0) Files.Append(P("events.in"), sb.ToString());
                            }
                            SendTo(sock, ACK, peerSess + " " + delivered.ToString(Proto.Inv), from);
                        }
                    }

                    // our events: until the friend has been heard from, drop them (the joiner gets a library snapshot
                    // instead, and a joiner's solo play from before connecting must not be replayed on the host)
                    if (peerSess == null) reader.Skip();
                    else
                    {
                        foreach (var e in reader.NewEvents()) { unacked[e.Key] = e.Value; lastResend = 0; }
                    }
                    if (peer != null && unacked.Count > 0 && Now() - lastResend > Resend)
                    {
                        foreach (var kv in unacked.Take(Window))
                        {
                            SendTo(sock, EV, mySess + " " + kv.Key.ToString(Proto.Inv) + " " + kv.Value, peer);
                            evSent++;
                        }
                        lastResend = Now();
                    }

                    // our position when it changed, or as keepalive
                    string me = Proto.ParseState(Files.ReadFirstLine(P("me.state")));
                    now = Now();
                    if (peer != null && me != null && (me != lastLine || now - lastSend > Keepalive))
                    {
                        SendTo(sock, MAGIC, mySess + " " + me, peer);
                        sent++;
                        lastSend = now;
                        lastLine = me;
                    }
                    if (peer != null && now - lastNameSend > NameEvery)
                    {
                        SendTo(sock, NAME, mySess + " " + myName, peer);
                        // read every time, so a colour picked while connected goes out within 2 s
                        SendTo(sock, COL, Proto.CleanColor(Files.ReadFirstLine(P("mycolor.txt"))), peer);
                        lastNameSend = now;
                    }

                    if (now - lastStatus > 1.0)
                    {
                        lastStatus = now;
                        var st = new Dictionary<string, string>();
                        st["role"] = role;
                        st["peer"] = peer != null ? peer.ToString() : "none";
                        st["peer_name"] = peerName ?? "";
                        st["peer_color"] = peerColor ?? "";
                        st["sent"] = sent.ToString(Proto.Inv);
                        st["recv"] = recv.ToString(Proto.Inv);
                        st["rejected"] = rejected.ToString(Proto.Inv);
                        st["last_recv_age"] = lastRecv > 0 ? (now - lastRecv).ToString("F1", Proto.Inv) : "never";
                        st["events_out"] = reader.Seq.ToString(Proto.Inv);
                        st["events_sent"] = evSent.ToString(Proto.Inv);
                        st["events_unacked"] = unacked.Count.ToString(Proto.Inv);
                        st["events_recv"] = evRecv.ToString(Proto.Inv);
                        st["events_delivered"] = delivered.ToString(Proto.Inv);
                        st["events_dup"] = evDup.ToString(Proto.Inv);
                        lock (statusLock) status = st;
                        Files.WriteAtomic(P("relay.status"), string.Join("", st.Select(kv => kv.Key + "=" + kv.Value + "\n")));
                    }
                }
            }
            catch (Exception ex)
            {
                Error = ex.Message;
            }
            finally
            {
                sock.Close();
            }
        }

        static void Split(string text, out string first, out string rest)
        {
            int sp = text.IndexOf(' ');
            if (sp < 0) { first = text; rest = ""; }
            else { first = text.Substring(0, sp); rest = text.Substring(sp + 1); }
        }

        static void SendTo(Socket sock, byte[] magic, string text, EndPoint to)
        {
            try
            {
                var body = Encoding.ASCII.GetBytes(text);
                var pkt = new byte[magic.Length + body.Length];
                Buffer.BlockCopy(magic, 0, pkt, 0, magic.Length);
                Buffer.BlockCopy(body, 0, pkt, magic.Length, body.Length);
                sock.SendTo(pkt, to);
            }
            catch (SocketException) { }
        }
    }

    static class SaveBackup
    {
        // Copy the game's SaveGames folder before playing together: the friend's world gets changed by the sync and
        // the game autosaves. At most one backup per hour, newest 10 kept.
        public static string Run()
        {
            string saved = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Librarian", "Saved");
            string src = Path.Combine(saved, "SaveGames");
            if (!Directory.Exists(src)) return "no saves found to back up";
            string root = Path.Combine(saved, "LibrarianCoop-backups");
            Directory.CreateDirectory(root);
            var existing = Directory.GetDirectories(root).OrderBy(d => d).ToList();
            if (existing.Count > 0 && (DateTime.Now - Directory.GetCreationTime(existing.Last())).TotalHours < 1)
                return "saves backed up earlier: " + Path.GetFileName(existing.Last());
            string dst = Path.Combine(root, DateTime.Now.ToString("yyyyMMdd-HHmmss", Proto.Inv));
            Copy(src, dst);
            existing.Add(dst);
            while (existing.Count > 10) { Directory.Delete(existing[0], true); existing.RemoveAt(0); }
            return "saves backed up to Saved\\LibrarianCoop-backups\\" + Path.GetFileName(dst);
        }

        static void Copy(string src, string dst)
        {
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)));
            foreach (var d in Directory.GetDirectories(src)) Copy(d, Path.Combine(dst, Path.GetFileName(d)));
        }
    }

    class LauncherForm : Form
    {
        const int DefaultPort = 7788;
        readonly string netdir, settingsPath;
        readonly bool noBackup;
        Relay relay;
        Thread thread;
        string color, backupNote = "";
        readonly TextBox nameBox, ipBox, portBox;
        readonly RadioButton hostRadio, joinRadio;
        readonly Panel swatch;
        readonly Label ipHint, connLabel, detailLabel, gameLabel;
        readonly Button startButton, tpButton;
        readonly System.Windows.Forms.Timer timer;

        public LauncherForm(string netdir, bool autostart, bool noBackup)
        {
            this.netdir = netdir;
            this.noBackup = noBackup;
            settingsPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "LibrarianCoop.ini");
            var s = Files.ReadKeyValues(settingsPath);

            Text = "Librarian Co-op " + Program.Version;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Segoe UI", 9f);
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(330, 430);
            int y = 14;
            Func<string, int, Label> label = (t, top) =>
            {
                var l = new Label { Text = t, Left = 14, Top = top + 3, Width = 90 };
                Controls.Add(l);
                return l;
            };

            label("Your name", y);
            nameBox = new TextBox { Left = 110, Top = y, Width = 200, MaxLength = 16, Text = Get(s, "name", Environment.UserName) };
            Controls.Add(nameBox);
            y += 32;

            label("Your colour", y);
            color = Proto.CleanColor(Get(s, "color", null));
            swatch = new Panel { Left = 110, Top = y + 1, Width = 40, Height = 22, BorderStyle = BorderStyle.FixedSingle, BackColor = ToColor(color) };
            Controls.Add(swatch);
            var colorButton = new Button { Text = "Change...", Left = 160, Top = y, Width = 150 };
            colorButton.Click += (o, e) => PickColor();
            Controls.Add(colorButton);
            y += 34;

            hostRadio = new RadioButton { Text = "Host (friends join me)", Left = 14, Top = y, Width = 290 };
            joinRadio = new RadioButton { Text = "Join a friend", Left = 14, Top = y + 26, Width = 290 };
            hostRadio.Checked = Get(s, "mode", "host") != "join";
            joinRadio.Checked = !hostRadio.Checked;
            hostRadio.CheckedChanged += (o, e) => RefreshMode();
            Controls.Add(hostRadio);
            Controls.Add(joinRadio);
            y += 58;

            label("Friend's IP", y);
            ipBox = new TextBox { Left = 110, Top = y, Width = 200, Text = Get(s, "ip", "") };
            Controls.Add(ipBox);
            y += 32;

            label("Port", y);
            portBox = new TextBox { Left = 110, Top = y, Width = 70, Text = Get(s, "port", DefaultPort.ToString(Proto.Inv)) };
            Controls.Add(portBox);
            y += 32;

            ipHint = new Label { Left = 14, Top = y, Width = 300, Height = 18, ForeColor = Color.DimGray, Text = IpHint() };
            Controls.Add(ipHint);
            y += 24;

            startButton = new Button { Text = "Start", Left = 14, Top = y, Width = 296, Height = 28 };
            startButton.Click += (o, e) => Toggle();
            Controls.Add(startButton);
            y += 34;

            tpButton = new Button { Text = "Teleport everyone to me", Left = 14, Top = y, Width = 296, Height = 28 };
            tpButton.Click += (o, e) => TeleportAll();
            Controls.Add(tpButton);
            y += 40;

            Controls.Add(new Label { Left = 14, Top = y, Width = 296, Height = 2, BorderStyle = BorderStyle.Fixed3D });
            y += 10;
            connLabel = new Label { Left = 14, Top = y, Width = 300, Height = 20, Font = new Font("Segoe UI", 9.5f, FontStyle.Bold), Text = "Not started" };
            Controls.Add(connLabel);
            y += 24;
            detailLabel = new Label { Left = 14, Top = y, Width = 300, Height = 34, ForeColor = Color.DimGray };
            Controls.Add(detailLabel);
            y += 36;
            gameLabel = new Label { Left = 14, Top = y, Width = 300, Height = 34, ForeColor = Color.DimGray };
            Controls.Add(gameLabel);

            RefreshMode();
            timer = new System.Windows.Forms.Timer { Interval = 500 };
            timer.Tick += (o, e) => Poll();
            timer.Start();
            FormClosing += (o, e) => { if (relay != null) relay.Stop = true; };
            if (autostart) Shown += (o, e) => Toggle();
        }

        static string Get(Dictionary<string, string> s, string k, string def)
        {
            string v;
            return s.TryGetValue(k, out v) ? v : def;
        }

        static Color ToColor(string rgb)
        {
            var p = rgb.Split(' ');
            return Color.FromArgb(int.Parse(p[0]), int.Parse(p[1]), int.Parse(p[2]));
        }

        static string IpHint()
        {
            var ips = new List<string>();
            try
            {
                foreach (var a in Dns.GetHostAddresses(Dns.GetHostName()))
                    if (a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)) ips.Add(a.ToString());
            }
            catch (Exception) { }
            var radmin = ips.FirstOrDefault(ip => ip.StartsWith("26.", StringComparison.Ordinal));
            if (radmin != null) return "Give your friend this Radmin IP: " + radmin;
            return ips.Count > 0 ? "Your IPs: " + string.Join(", ", ips) : "No network address found";
        }

        void RefreshMode()
        {
            bool joining = joinRadio.Checked;
            ipBox.Enabled = joining;
            ipHint.Visible = !joining;
            tpButton.Visible = !joining;
        }

        void Save(int port)
        {
            var sb = new StringBuilder();
            sb.Append("name=").Append(Proto.CleanName(nameBox.Text)).Append('\n');
            sb.Append("mode=").Append(joinRadio.Checked ? "join" : "host").Append('\n');
            sb.Append("ip=").Append(ipBox.Text.Trim()).Append('\n');
            sb.Append("port=").Append(port.ToString(Proto.Inv)).Append('\n');
            sb.Append("color=").Append(color).Append('\n');
            try { File.WriteAllText(settingsPath, sb.ToString(), Encoding.ASCII); } catch (Exception) { }
        }

        void PickColor()
        {
            using (var dlg = new ColorDialog { Color = ToColor(color), FullOpen = true })
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                color = Proto.CleanColor(dlg.Color.R + " " + dlg.Color.G + " " + dlg.Color.B);
                swatch.BackColor = ToColor(color);
                int port;
                Save(int.TryParse(portBox.Text, out port) ? port : DefaultPort);
                // the running relay re-reads this file every 2 s, so friends see the new colour right away
                try { Directory.CreateDirectory(netdir); Files.WriteAtomic(Path.Combine(netdir, "mycolor.txt"), color + "\n"); } catch (Exception) { }
            }
        }

        void TeleportAll()
        {
            if (thread == null || !thread.IsAlive) { connLabel.Text = "Start hosting first"; return; }
            // an event for the relay to deliver reliably; the friends' mods move them next to you
            Files.Append(Path.Combine(netdir, "events.out"), "0 tp\n");
            connLabel.Text = "Teleport sent";
        }

        void Toggle()
        {
            if (thread != null && thread.IsAlive)
            {
                relay.Stop = true;
                startButton.Text = "Stopping...";
                return;
            }
            int port;
            if (!int.TryParse(portBox.Text.Trim(), out port) || port < 1 || port > 65535) { connLabel.Text = "Port must be a number"; return; }
            string name = Proto.CleanName(nameBox.Text);
            nameBox.Text = name;
            IPEndPoint target = null;
            if (joinRadio.Checked)
            {
                IPAddress ip;
                if (!IPAddress.TryParse(ipBox.Text.Trim(), out ip)) { connLabel.Text = "Type your friend's IP first (like 26.1.2.3)"; return; }
                target = new IPEndPoint(ip, port);
            }
            Save(port);
            if (!noBackup)
            {
                try { backupNote = SaveBackup.Run(); }
                catch (Exception ex) { backupNote = "save backup failed: " + ex.Message; }
            }
            try { relay = new Relay(netdir, joinRadio.Checked ? 0 : port, target, name, color); }
            catch (Exception ex) { connLabel.Text = "Could not start: " + ex.Message; relay = null; return; }
            var r = relay;
            thread = new Thread(() => r.Run(0)) { IsBackground = true };
            thread.Start();
            startButton.Text = "Stop";
            connLabel.Text = "Starting...";
        }

        void Poll()
        {
            bool running = thread != null && thread.IsAlive;
            if (!running)
            {
                if (startButton.Text != "Start") startButton.Text = "Start";
                if (relay != null && relay.Error != null) connLabel.Text = "Could not start: " + relay.Error;
                else if (thread != null) connLabel.Text = "Stopped";
            }
            else
            {
                var st = relay.Status;
                if (st.Count > 0)
                {
                    double age;
                    bool fresh = double.TryParse(st["last_recv_age"], NumberStyles.Float, Proto.Inv, out age) && age < 3;
                    if (fresh) connLabel.Text = "Connected to " + (st["peer_name"] != "" ? st["peer_name"] : "friend") + " (" + st["peer"] + ")";
                    else if (st["role"] == "host") connLabel.Text = "Waiting for a friend on port " + portBox.Text + "...";
                    else connLabel.Text = "Trying to reach " + st["peer"] + "...";
                    detailLabel.Text = "Last packet " + (st["last_recv_age"] == "never" ? "never" : st["last_recv_age"] + "s ago") +
                        " · book events sent " + st["events_out"] + ", received " + st["events_delivered"] +
                        (backupNote != "" ? "\n" + backupNote : "");
                }
            }
            var mod = Files.ReadKeyValues(Path.Combine(netdir, "mod.status"));
            string t;
            long ts;
            bool modFresh = mod.TryGetValue("time", out t) && long.TryParse(t, out ts) &&
                (DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds - ts < 5;
            if (!modFresh) gameLabel.Text = "Game: not running (start Librarian with the mod installed)";
            else
            {
                string state = mod.ContainsKey("state") ? mod["state"] : "";
                string sync = mod.ContainsKey("librarySync") ? mod["librarySync"] : "";
                gameLabel.Text = "Game: " + (state == "no-pawn" ? "on a menu" : "in the library") +
                    (sync != "" && sync != "none" ? "\nLibrary sync: " + (sync.Contains("done") || sync.Contains("nothing") ? "done" : sync) : "");
            }
        }
    }

    static class Program
    {
        public const string Version = "0.1.0";

        static string Arg(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }

        // the mod's state folder: next to the exe in the game folder, or next to the exe inside the mod folder
        static string DefaultNetdir()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string inGame = Path.Combine(baseDir, "Librarian", "Binaries", "Win64", "ue4ss", "Mods", "LibrarianCoop");
            if (Directory.Exists(inGame)) return Path.Combine(inGame, "net");
            return Path.Combine(baseDir, "net");
        }

        [STAThread]
        static int Main(string[] args)
        {
            string netdir = Arg(args, "--netdir") ?? DefaultNetdir();
            if (args.Contains("--relay"))
            {
                // headless relay for tests: same code as the window uses
                string listen = Arg(args, "--listen"), connect = Arg(args, "--connect");
                IPEndPoint target = null;
                if (connect != null)
                {
                    int c = connect.LastIndexOf(':');
                    target = new IPEndPoint(IPAddress.Parse(connect.Substring(0, c)), int.Parse(connect.Substring(c + 1), Proto.Inv));
                }
                string secs = Arg(args, "--seconds");
                var relay = new Relay(netdir, listen != null ? int.Parse(listen, Proto.Inv) : 0, target, Arg(args, "--name") ?? "Player", Arg(args, "--color"));
                relay.Run(secs != null ? double.Parse(secs, Proto.Inv) : 0);
                return relay.Error == null ? 0 : 1;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (o, e) =>
                MessageBox.Show(e.Exception.Message, "Librarian Co-op", MessageBoxButtons.OK, MessageBoxIcon.Error);
            try
            {
                Application.Run(new LauncherForm(netdir, args.Contains("--autostart"), args.Contains("--no-backup")));
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Librarian Co-op", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return 0;
        }
    }
}
