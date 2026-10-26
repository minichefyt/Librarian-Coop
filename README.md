LIBRARIAN CO-OP 0.1.0  (test build)
Play "Librarian: Tidy Up the Arcane Library!" together over Radmin VPN.
====================================================================

WHAT IT DOES
- You see your friend as a coloured bean with their name above it.
- Books are shared: picking up, carrying, shelving and dropping books shows up for both of you.
- A friend who joins later gets the host's library (shelves and floor) when they connect.
- The host can teleport everyone to them.
Each player still has their own level, skills and upgrades.

WHAT EVERYONE NEEDS
- Their own copy of the game on Steam.
- Radmin VPN (radmin-vpn.com), all in the same Radmin network.
- Windows 10 or 11. Nothing else to install.


INSTALL (every player, once)
1. In Steam: right-click Librarian > Manage > Browse local files. A folder opens; it contains Librarian.exe.
2. Unzip this whole package INTO that folder, so LibrarianCoop.exe sits next to Librarian.exe.
   If Windows asks to merge the "Librarian" folder, say Yes. Nothing of the game is replaced; files are only added.
3. Done. (This adds UE4SS, a free mod loader, and the LibrarianCoop mod.)


PLAY
Host (one player):
1. Start Librarian from Steam and load your game (or start a New Game).
2. Double-click LibrarianCoop.exe in the game folder.
3. Type your name, pick a colour, choose "Host", press Start.
4. If Windows Firewall asks, click "Allow access" (tick both Private and Public networks).
5. The window shows "Give your friend this Radmin IP: 26.x.x.x". Send that to your friend.

Friend (everyone else):
1. Start Librarian from Steam and START A NEW GAME (recommended, see SAVES below).
2. Double-click LibrarianCoop.exe in the game folder.
3. Type your name, pick a colour, choose "Join a friend", type the host's 26.x.x.x IP, press Start.
4. When it says "Connected to <host>", the host's library is copied to your game
   ("Library sync: done" at the bottom of the window). A few books may fly onto shelves at that moment.

Both: keep the LibrarianCoop window open while you play (you can minimise it).


SAVES - PLEASE READ
- When you press Start, the launcher copies your saves to
  %LOCALAPPDATA%\Librarian\Saved\LibrarianCoop-backups\<date-time>  (the last 10 are kept).
- A friend who joins gets their library changed to match the host's, and the game autosaves that.
  So friends should start a New Game (or use a save they don't mind changing).
- To restore a backup: close the game, then copy the files from a backup folder back into
  %LOCALAPPDATA%\Librarian\Saved\SaveGames.


IF SOMETHING DOES NOT WORK
- "Trying to reach ..." forever: check both are in the same Radmin network (the host's name is green in Radmin),
  the IP is the host's 26.x.x.x address, and the host allowed LibrarianCoop.exe in Windows Firewall.
- "Game: not running": the mod is not installed in that game folder. Check that
  Librarian\Binaries\Win64\dwmapi.dll and Librarian\Binaries\Win64\ue4ss\ exist next to the game.
- Windows SmartScreen says "Windows protected your PC": click "More info" > "Run anyway"
  (the launcher is not code-signed).
- Port: both players must use the same port (default 7788). Change it only if something else uses 7788.


KNOWN LIMITS OF THIS TEST BUILD
- 2 players only (one host, one friend).
- Only books are shared. Levels, skills, upgrades, keys and chests stay per player.
- If both grab the same book at the same moment, the host gets it.
- Tested on one PC with two copies of the game; this is the first test across two PCs.
  If something goes wrong, note what you did and send the "net" folder from
  Librarian\Binaries\Win64\ue4ss\Mods\LibrarianCoop\ plus Librarian\Binaries\Win64\ue4ss\UE4SS.log.


UNINSTALL
Delete these from the game folder:
  LibrarianCoop.exe, LibrarianCoop.ini, README.txt (this file), source\
  Librarian\Binaries\Win64\dwmapi.dll
  Librarian\Binaries\Win64\ue4ss\  (whole folder)
The game is then exactly as before. Your saves and the backups in Saved\LibrarianCoop-backups stay.


CREDITS / LICENCES
- UE4SS (RE-UE4SS, MIT licence): Librarian\Binaries\Win64\ue4ss\LICENSE. Build UE4SS_v3.0.1-1183-gcdbc0b66.
- LibrarianCoop mod and launcher: MIT licence, see LICENSE.txt. Source in source\ and in the mod folder.
- Librarian is (c) ArtRising. This package contains no game files.
