import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const LgRemoteApp());

const bg = Color(0xffffffff),
    panel = Color(0xff152235),
    mint = Color(0xff9effc9),
    emerald = Color(0xff10b981),
    green = Color(0xff00a85a),
    ink = Color(0xff17212d),
    subtle = Color(0xff667383),
    lightText = Color(0xffd7ffe8);

class LgRemoteApp extends StatelessWidget {
  const LgRemoteApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LG webOS Remote',
      theme: ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: bg,
          colorScheme: ColorScheme.fromSeed(
              seedColor: emerald, brightness: Brightness.light),
          useMaterial3: true),
      home: const RemoteHome());
}

class RemoteHome extends StatefulWidget {
  const RemoteHome({super.key});
  @override
  State<RemoteHome> createState() => _RemoteHomeState();
}

class _RemoteHomeState extends State<RemoteHome>
    with SingleTickerProviderStateMixin {
  final ip = TextEditingController(),
      toast = TextEditingController(),
      keyboard = TextEditingController();
  WebSocket? socket, pointer;
  String? clientKey;
  int tab = 0;
  bool connected = false, connecting = false, muted = false, trackpad = true;
  bool discovering = false;
  bool connectionNoticeShown = false;
  late final AnimationController _statusPulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);
  double wheelRotation = 0;
  double wheelOffset = 0;
  Offset? pointerPosition;
  String status = 'Disconnected';
  bool get ready => connected && socket != null;
  static const permissions = [
    'LAUNCH',
    'CONTROL_AUDIO',
    'CONTROL_DISPLAY',
    'CONTROL_POWER',
    'CONTROL_INPUT_TV',
    'CONTROL_MOUSE_AND_KEYBOARD',
    'CONTROL_INPUT_JOYSTICK',
    'CONTROL_INPUT_MEDIA_PLAYBACK',
    'READ_INSTALLED_APPS'
  ];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    ip.text = p.getString('tv_ip') ?? '';
    clientKey = p.getString('client_key');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !connected && !discovering) discoverTv();
    });
  }

  Map<String, dynamic> _registration() => {
        'type': 'register',
        'id': 'register_0',
        'payload': {
          'forcePairing': false,
          'pairingType': 'PROMPT',
          if (clientKey != null) 'client-key': clientKey,
          'manifest': {
            'manifestVersion': 1,
            'appVersion': '1.0.0',
            'signed': {
              'created': '20261023',
              'appId': 'com.vasants.lgremote',
              'vendorId': 'com.vasants',
              'localizedAppNames': {'': 'LG webOS Remote'},
              'localizedVendorNames': {'': 'Vasants'},
              'permissions': permissions,
              'serial': 'vasants-lg-remote-2026'
            },
            'permissions': permissions
          }
        }
      };

  Future<void> connect() async {
    final address = ip.text.trim();
    if (address.isEmpty) return _notice('Enter your LG TV IP address.');
    await disconnect(update: false);
    setState(() {
      connecting = true;
      status = 'Connecting to $address…';
    });
    try {
      final s = await WebSocket.connect('ws://$address:3000')
          .timeout(const Duration(seconds: 7));
      socket = s;
      s.listen(_message, onDone: _closed, onError: (_) => _closed());
      s.add(jsonEncode(_registration()));
      final p = await SharedPreferences.getInstance();
      await p.setString('tv_ip', address);
      if (mounted) {
        setState(() => status = 'Approve pairing on your TV');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          connecting = false;
          status = 'Connection failed';
        });
      }
      _notice('Check the IP address, Wi-Fi and TV network settings.');
    }
  }

  void _message(dynamic raw) {
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      if (m['type'] == 'registered') {
        clientKey = m['payload']?['client-key'] as String?;
        SharedPreferences.getInstance().then((p) {
          if (clientKey != null) p.setString('client_key', clientKey!);
        });
        if (!mounted) return;
        setState(() {
          connected = true;
          connecting = false;
          connectionNoticeShown = false;
          status = 'Connected to LG webOS TV';
        });
        command('ssap://com.webos.service.networkinput/getPointerInputSocket',
            id: 'pointer_socket');
      } else if (m['id'] == 'pointer_socket') {
        final path = m['payload']?['socketPath'] as String?;
        if (path != null) _openPointer(path);
      }
    } catch (_) {}
  }

  Future<void> _openPointer(String path) async {
    try {
      pointer = await WebSocket.connect(path);
    } catch (_) {
      if (mounted) _notice('Pointer socket unavailable. Reconnect to the TV.');
    }
  }

  void command(String uri,
      {Map<String, dynamic> payload = const {}, String? id}) {
    HapticFeedback.mediumImpact();
    if (!ready) {
      _connectionWarning();
      return;
    }
    socket!.add(jsonEncode({
      'id': id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      'type': 'request',
      'uri': uri,
      'payload': payload
    }));
  }

  void key(String name) {
    HapticFeedback.mediumImpact();
    if (!ready || pointer == null) return;
    pointer!.add('type:button\nname:$name\n\n');
  }

  void mouse(String type, {double dx = 0, double dy = 0}) {
    if (type == 'scroll') {
      HapticFeedback.selectionClick();
    } else {
      HapticFeedback.mediumImpact();
    }
    if (!ready || pointer == null) return;
    pointer!.add(type == 'move'
        ? 'type:move\ndx:${dx.round()}\ndy:${dy.round()}\n\n'
        : 'type:$type\n\n');
  }

  Future<void> disconnect({bool update = true}) async {
    await socket?.close();
    await pointer?.close();
    socket = null;
    pointer = null;
    if (mounted) {
      setState(() {
        connected = false;
        connecting = false;
        if (update) status = 'Disconnected';
      });
    }
  }

  void _closed() {
    if (mounted) {
      setState(() {
        connected = false;
        connecting = false;
        status = 'TV connection closed';
      });
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _connectionWarning() {
    if (connectionNoticeShown) return;
    connectionNoticeShown = true;
    _notice('Connect to the TV first.');
  }

  Future<void> discoverTv() async {
    if (discovering) return;
    setState(() {
      discovering = true;
      status = 'Searching this Wi-Fi network…';
    });
    RawDatagramSocket? udp;
    final found = <String>{};
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udp.broadcastEnabled = true;
      const request = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
      final bytes = utf8.encode(request);
      final target = InternetAddress('239.255.255.250');
      udp.send(bytes, target, 1900);
      Future<void>.delayed(const Duration(seconds: 3), () => udp?.close());
      await for (final event in udp) {
        if (event != RawSocketEvent.read) continue;
        final packet = udp.receive();
        if (packet == null) continue;
        final text = utf8.decode(packet.data, allowMalformed: true);
        final location =
            RegExp(r'LOCATION:\s*[^:/]+://([^/:]+)', caseSensitive: false)
                .firstMatch(text);
        final address = location?.group(1) ?? packet.address.address;
        if (address.isNotEmpty) found.add(address);
      }
    } catch (_) {
      // Discovery is best effort; manual IP entry remains available.
    } finally {
      udp?.close();
    }
    if (!mounted) return;
    setState(() => discovering = false);
    if (found.isEmpty) {
      setState(() =>
          status = 'No TV found. Check that both devices use the same Wi-Fi.');
      return;
    }
    ip.text = found.first;
    final p = await SharedPreferences.getInstance();
    await p.setString('tv_ip', ip.text);
    setState(() => status = 'TV found at ${ip.text}');
    await connect();
  }

  @override
  void dispose() {
    _statusPulse.dispose();
    socket?.close();
    pointer?.close();
    ip.dispose();
    toast.dispose();
    keyboard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
          body: SafeArea(
              child: Column(children: [
        _header(),
        Expanded(
            child: IndexedStack(
                index: tab,
                children: [_mainRemote(), _touchPad(), _appsHub(), _tools()])),
        _bottomBar()
      ]))));

  Future<void> _confirmExit() async {
    final exit = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Exit remote?'),
              content: const Text('Do you want to close the LG TV Remote app?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('CANCEL')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('EXIT'))
              ],
            ));
    if (exit == true && mounted) SystemNavigator.pop();
  }

  Widget _header() => SizedBox(
      height: 22,
      child: Align(
          alignment: Alignment.topRight,
          child: AnimatedBuilder(
              animation: _statusPulse,
              builder: (context, child) => Opacity(
                  opacity: .55 + (_statusPulse.value * .45),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle,
                        size: 8, color: connected ? green : Colors.redAccent),
                    const SizedBox(width: 5),
                    Text(connected ? 'ONLINE' : 'OFFLINE',
                        style: TextStyle(
                            color: connected ? green : Colors.redAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold))
                  ])))));

  Widget _mainRemote() => _remoteScroll(
          Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _sectionTitle('Main Remote', 'मुख्य रिमोट'),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _action(Icons.power_settings_new_rounded, 'POWER', Colors.redAccent,
              () => command('ssap://system/turnOff')),
          _action(Icons.input_rounded, 'SOURCE', mint,
              () => command('ssap://tv/switchInput')),
          _action(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              muted ? 'UNMUTE' : 'MUTE', Colors.orangeAccent, () {
            muted = !muted;
            setState(() {});
            command('ssap://audio/setMute', payload: {'mute': muted});
          })
        ]),
        const SizedBox(height: 18),
        Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClayRocker(
                  title: 'VOL',
                  up: () => command('ssap://audio/volumeUp'),
                  down: () => command('ssap://audio/volumeDown')),
              _dpad(),
              ClayRocker(
                  title: 'CH',
                  up: () => command('ssap://tv/channelUp'),
                  down: () => command('ssap://tv/channelDown'))
            ]),
        const SizedBox(height: 18),
        Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _smallKey('BACK', Icons.arrow_back_rounded, () => key('BACK')),
              _smallKey('HOME', Icons.home_rounded, () => key('HOME')),
              _smallKey('MENU', Icons.menu_rounded, () => key('MENU')),
              _smallKey('EXIT', Icons.close_rounded, () => key('EXIT'))
            ]),
        const SizedBox(height: 16),
        _colorRow(),
        const SizedBox(height: 16),
        _transport()
      ]));

  Widget _remoteScroll(Widget child) => LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: ConstrainedBox(
              constraints: BoxConstraints(
                  minHeight: constraints.maxHeight > 10
                      ? constraints.maxHeight - 10
                      : 0),
              child: child)));
  Widget _dpad() => ClayContainer(
      radius: 100,
      color: const Color(0xff8a929d),
      padding: const EdgeInsets.all(12),
      child: SizedBox(
          width: 214,
          height: 214,
          child: Stack(alignment: Alignment.center, children: [
            _positioned(Icons.keyboard_arrow_up_rounded, Alignment.topCenter,
                () => key('UP')),
            _positioned(Icons.keyboard_arrow_down_rounded,
                Alignment.bottomCenter, () => key('DOWN')),
            _positioned(Icons.keyboard_arrow_left_rounded, Alignment.centerLeft,
                () => key('LEFT')),
            _positioned(Icons.keyboard_arrow_right_rounded,
                Alignment.centerRight, () => key('RIGHT')),
            ClayButton(
                label: 'OK',
                onTap: () => key('ENTER'),
                circle: false,
                accent: true,
                fillColor: Colors.redAccent,
                color: lightText)
          ])));
  Widget _positioned(IconData icon, Alignment alignment, VoidCallback action) =>
      Align(
          alignment: alignment,
          child: ClayButton(
              icon: icon, onTap: action, circle: true, iconOnly: true));

  Widget _touchPad() => _scroll(Column(children: [
        _sectionTitle('Touchpad & Number Pad', 'टचपैड और नंबर पैड'),
        _toggle(),
        const SizedBox(height: 16),
        if (trackpad) _trackpad() else _numberPad()
      ]));
  Widget _toggle() => ClayContainer(
      padding: const EdgeInsets.all(5),
      radius: 30,
      child: Row(children: [
        Expanded(
            child: _toggleChoice('Magic Trackpad', trackpad,
                () => setState(() => trackpad = true))),
        Expanded(
            child: _toggleChoice('0–9 Number Pad', !trackpad,
                () => setState(() => trackpad = false)))
      ]));
  Widget _toggleChoice(String text, bool selected, VoidCallback tap) =>
      GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            tap();
          },
          child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                  color: selected ? emerald : Colors.transparent,
                  borderRadius: BorderRadius.circular(24)),
              child: Center(
                  child: Text(text,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: selected ? lightText : subtle)))));
  Widget _trackpad() =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: GestureDetector(
                onPanStart: (d) =>
                    setState(() => pointerPosition = d.localPosition),
                onPanUpdate: (d) {
                  setState(() => pointerPosition = d.localPosition);
                  mouse('move', dx: d.delta.dx * 2.4, dy: d.delta.dy * 2.4);
                },
                onTap: () => mouse('click'),
                child: ClayContainer(
                    height: 300,
                    radius: 34,
                    child: Stack(children: [
                      const Center(
                          child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                            Icon(Icons.mouse_rounded, size: 48, color: ink),
                            SizedBox(height: 10),
                            Text('Touch to move pointer',
                                style: TextStyle(color: subtle)),
                            Text('Tap to select',
                                style: TextStyle(color: subtle))
                          ])),
                      if (pointerPosition != null)
                        Positioned(
                            left: pointerPosition!.dx - 7,
                            top: pointerPosition!.dy - 7,
                            child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                    color: ink.withValues(alpha: .75),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: mint, width: 2))))
                    ])))),
        const SizedBox(width: 12),
        ClayContainer(
            width: 68,
            height: 300,
            radius: 30,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            child: GestureDetector(
                onVerticalDragStart: (_) => HapticFeedback.mediumImpact(),
                onVerticalDragUpdate: (d) {
                  setState(
                      () => wheelOffset = (wheelOffset + d.delta.dy * .8) % 22);
                  mouse('scroll', dy: d.delta.dy);
                },
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                        color: const Color(0xff080f18),
                        child: Stack(clipBehavior: Clip.hardEdge, children: [
                          Transform.translate(
                              offset: Offset(0, wheelOffset - 11),
                              child: Column(children: [
                                for (int i = 0; i < 32; i++)
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 3),
                                      child: Container(
                                          height: 3,
                                          margin: const EdgeInsets.symmetric(
                                              horizontal: 4),
                                          decoration: BoxDecoration(
                                              color: i.isEven
                                                  ? mint
                                                  : const Color(0xff718197),
                                              borderRadius:
                                                  BorderRadius.circular(2))))
                              ])),
                          Center(
                              child: Container(
                                  width: 34,
                                  height: 58,
                                  decoration: BoxDecoration(
                                      color: const Color(0xff304158),
                                      borderRadius: BorderRadius.circular(17),
                                      border:
                                          Border.all(color: mint, width: 1.5),
                                      boxShadow: const [
                                        BoxShadow(
                                            color: Color(0xaa000000),
                                            offset: Offset(2, 3),
                                            blurRadius: 6)
                                      ]),
                                  child: const Icon(Icons.swap_vert_rounded,
                                      color: mint, size: 25)))
                        ])))))
      ]);
  Widget _numberPad() => GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.45,
          children: [
            for (final n in [
              '1',
              '2',
              '3',
              '4',
              '5',
              '6',
              '7',
              '8',
              '9',
              'LIST',
              '0',
              'INFO'
            ])
              ClayButton(
                  label: n,
                  onTap: () => key(n == 'LIST' || n == 'INFO' ? n : 'NUM_$n'))
          ]);

  Widget _appsHub() =>
      _scroll(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Apps & Media Hub', 'ऐप्स और मीडिया'),
        GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.15,
            children: [
              _app('YouTube', Icons.play_circle_fill_rounded, Colors.redAccent,
                  'youtube.leanback.v4'),
              _app(
                  'Netflix', Icons.movie_filter_rounded, Colors.red, 'netflix'),
              _app('Prime Video', Icons.live_tv_rounded, Colors.lightBlueAccent,
                  'amazon'),
              _app('Disney+ Hotstar', Icons.star_rounded, Colors.blueAccent,
                  'hotstar'),
              _app('LG Store', Icons.storefront_rounded, mint,
                  'com.webos.app.discovery'),
              _app('Web Browser', Icons.language_rounded, Colors.orangeAccent,
                  'com.webos.app.browser'),
              _app('HDMI 1', Icons.cable_rounded, Colors.purpleAccent,
                  'com.webos.app.hdmi1'),
              _app('HDMI 2', Icons.cable_rounded, Colors.pinkAccent,
                  'com.webos.app.hdmi2')
            ])
      ]));
  Widget _app(String name, IconData icon, Color color, String id) =>
      GestureDetector(
          onTap: () =>
              command('ssap://system.launcher/launch', payload: {'id': id}),
          child: ClayContainer(
              radius: 30,
              padding: const EdgeInsets.all(10),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: color, size: 29),
                    const SizedBox(height: 7),
                    Text(name,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: lightText,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))
                  ])));

  Widget _tools() =>
      _scroll(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Smart Tools & Keyboard', 'स्मार्ट टूल्स और मैसेज'),
        _connectionTools(),
        _toolCard(
            'TV Toast Notification',
            Icons.notifications_active_rounded,
            TextField(
                controller: toast,
                decoration:
                    const InputDecoration(hintText: 'Message shown on the TV')),
            ClayButton(
                label: 'Send to TV Screen',
                icon: Icons.send_rounded,
                onTap: () => command('ssap://system.notifications/createToast',
                    payload: {'message': toast.text}))),
        _toolCard(
            'Remote Keyboard Input',
            Icons.keyboard_rounded,
            TextField(
                controller: keyboard,
                decoration: const InputDecoration(
                    hintText: 'Type into the TV search bar')),
            Row(children: [
              Expanded(
                  child: ClayButton(
                      label: 'Send Text',
                      icon: Icons.text_fields_rounded,
                      onTap: () => command(
                          'ssap://com.webos.service.ime/insertText',
                          payload: {'text': keyboard.text, 'replace': 0}))),
              const SizedBox(width: 8),
              ClayButton(
                  label: 'Enter',
                  icon: Icons.keyboard_return_rounded,
                  onTap: () => key('ENTER'))
            ])),
        const SizedBox(height: 14),
        const Text('Quick System Controls',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          ClayButton(
              label: 'Screen Off',
              icon: Icons.dark_mode_rounded,
              onTap: () =>
                  command('ssap://com.webos.service.tvpower/powerOff')),
          ClayButton(
              label: 'Audio Output',
              icon: Icons.speaker_rounded,
              onTap: () =>
                  command('ssap://com.webos.service.audio/getSoundOutput')),
          ClayButton(
              label: 'System Info',
              icon: Icons.info_outline_rounded,
              onTap: () => command('ssap://system/getSystemInfo'))
        ]),
        const SizedBox(height: 10),
        ClayContainer(
            radius: 18,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.auto_awesome_rounded, color: mint, size: 18),
              const SizedBox(width: 9),
              Column(children: [
                Text('DESIGNED & DEVELOPED BY',
                    style: TextStyle(
                        color: mint.withValues(alpha: .75),
                        fontSize: 9,
                        letterSpacing: 1.6,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                const Text('GARJE VASANT',
                    style: TextStyle(
                        color: lightText,
                        fontSize: 14,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'serif'))
              ])
            ]))
      ]));

  Widget _connectionTools() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: ClayContainer(
            radius: 30,
            padding: const EdgeInsets.all(13),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.wifi_find_rounded, color: mint),
                SizedBox(width: 8),
                Text('TV Connection',
                    style: TextStyle(
                        color: lightText,
                        fontWeight: FontWeight.bold,
                        fontSize: 16))
              ]),
              const SizedBox(height: 9),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: ip,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            hintText: 'TV IP e.g. 192.168.1.50',
                            prefixIcon: Icon(Icons.tv_rounded),
                            isDense: true))),
                const SizedBox(width: 8),
                ClayButton(
                    label: discovering ? 'Searching…' : 'Auto Find',
                    icon: Icons.search_rounded,
                    compact: true,
                    onTap: discovering ? null : discoverTv)
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: Text(status,
                        style: const TextStyle(color: subtle, fontSize: 12))),
                ClayButton(
                    label: connected ? 'Disconnect' : 'Connect',
                    icon: connected ? Icons.link_off : Icons.link,
                    compact: true,
                    onTap:
                        connecting ? null : (connected ? disconnect : connect))
              ])
            ])),
      );
  Widget _toolCard(String title, IconData icon, Widget field, Widget button) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ClayContainer(
              radius: 30,
              padding: const EdgeInsets.all(13),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(icon, color: mint),
                      const SizedBox(width: 8),
                      Text(title,
                          style: const TextStyle(
                              color: lightText,
                              fontWeight: FontWeight.bold,
                              fontSize: 16))
                    ]),
                    const SizedBox(height: 8),
                    field,
                    const SizedBox(height: 9),
                    button
                  ])));

  Widget _bottomBar() => Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: ClayContainer(
          radius: 30,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _nav(Icons.gamepad_rounded, 'Remote', 0),
            _nav(Icons.touch_app_rounded, 'Touchpad', 1),
            _nav(Icons.apps_rounded, 'Apps', 2),
            _nav(Icons.build_circle_rounded, 'Tools', 3)
          ])));
  Widget _nav(IconData icon, String label, int index) => GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        setState(() => tab = index);
      },
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: tab == index ? emerald : Colors.transparent,
              borderRadius: BorderRadius.circular(22)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22, color: tab == index ? lightText : subtle),
            Text(label,
                style: TextStyle(
                    fontSize: 10, color: tab == index ? lightText : subtle))
          ])));
  Widget _scroll(Widget child) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 18), child: child);
  Widget _sectionTitle(String title, String subtitle) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 23, fontWeight: FontWeight.w900))),
        Text(subtitle, style: const TextStyle(color: subtle, fontSize: 12))
      ]));
  Widget _action(IconData icon, String text, Color color, VoidCallback tap) =>
      Column(children: [
        ClayButton(
            icon: icon, onTap: tap, circle: true, color: color, iconOnly: true),
        const SizedBox(height: 4),
        Text(text,
            style: const TextStyle(
                fontSize: 10, color: subtle, fontWeight: FontWeight.bold))
      ]);
  Widget _smallKey(String text, IconData icon, VoidCallback tap) =>
      ClayButton(label: text, icon: icon, onTap: tap, compact: true);
  Widget _colorRow() =>
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        for (final item in [
          ('RED', Colors.redAccent),
          ('GREEN', green),
          ('YELLOW', Colors.amber),
          ('BLUE', Colors.blueAccent)
        ])
          ClayButton(
              label: item.$1,
              color: lightText,
              fillColor: item.$2,
              compact: true,
              onTap: () => key(item.$1))
      ]);
  Widget _transport() => ClayContainer(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      radius: 30,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        for (final item in [
          (Icons.fast_rewind_rounded, 'REWIND'),
          (Icons.play_arrow_rounded, 'PLAY'),
          (Icons.pause_rounded, 'PAUSE'),
          (Icons.stop_rounded, 'STOP'),
          (Icons.fast_forward_rounded, 'FF')
        ])
          IconButton(
              onPressed: () => key(item.$2),
              icon: Icon(item.$1, color: mint, size: 28))
      ]));
}

class ClayContainer extends StatelessWidget {
  const ClayContainer(
      {super.key,
      required this.child,
      this.width,
      this.height,
      this.padding = EdgeInsets.zero,
      this.radius = 30,
      this.color = panel});
  final Widget child;
  final double? width, height, radius;
  final EdgeInsets padding;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius!),
          boxShadow: const [
            BoxShadow(
                color: Color(0x66101820), offset: Offset(8, 9), blurRadius: 14),
            BoxShadow(
                color: Color(0x331f3445),
                offset: Offset(-5, -5),
                blurRadius: 12)
          ]),
      child: child);
}

class ClayButton extends StatefulWidget {
  const ClayButton(
      {super.key,
      this.label,
      this.icon,
      required this.onTap,
      this.color = mint,
      this.compact = false,
      this.circle = false,
      this.iconOnly = false,
      this.accent = false,
      this.fillColor = panel});
  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color color;
  final Color? fillColor;
  final bool compact, circle, iconOnly, accent;
  @override
  State<ClayButton> createState() => _ClayButtonState();
}

class _ClayButtonState extends State<ClayButton> {
  bool pressed = false, hovered = false;
  void _down(TapDownDetails _) {
    if (widget.onTap != null) {
      HapticFeedback.mediumImpact();
      setState(() => pressed = true);
    }
  }

  void _up(TapUpDetails _) {
    if (pressed) {
      setState(() => pressed = false);
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
          onTapDown: _down,
          onTapUp: _up,
          onTapCancel: () => setState(() => pressed = false),
          child: AnimatedScale(
              scale: pressed ? .92 : (hovered ? .97 : 1),
              duration: const Duration(milliseconds: 100),
              child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  constraints: widget.circle
                      ? const BoxConstraints(minWidth: 56, minHeight: 56)
                      : null,
                  padding: widget.circle
                      ? const EdgeInsets.all(12)
                      : EdgeInsets.symmetric(
                          horizontal: widget.compact ? 12 : 17,
                          vertical: widget.compact ? 10 : 14),
                  decoration: BoxDecoration(
                      color:
                          widget.fillColor ?? (widget.accent ? emerald : panel),
                      shape:
                          widget.circle ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: widget.circle
                          ? null
                          : BorderRadius.circular(widget.compact ? 20 : 25),
                      boxShadow: pressed
                          ? const [
                              BoxShadow(
                                  color: Color(0x66101820),
                                  offset: Offset(2, 3),
                                  blurRadius: 5)
                            ]
                          : const [
                              BoxShadow(
                                  color: Color(0x66101820),
                                  offset: Offset(5, 6),
                                  blurRadius: 9),
                              BoxShadow(
                                  color: Color(0x331f3445),
                                  offset: Offset(-3, -3),
                                  blurRadius: 7)
                            ]),
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.icon != null)
                          Icon(widget.icon,
                              color: widget.color,
                              size: widget.compact ? 18 : 23),
                        if (widget.icon != null &&
                            widget.label != null &&
                            !widget.iconOnly)
                          const SizedBox(width: 7),
                        if (widget.label != null && !widget.iconOnly)
                          Text(widget.label!,
                              style: TextStyle(
                                  color:
                                      widget.fillColor == bg ? bg : lightText,
                                  fontWeight: FontWeight.w800,
                                  fontSize: widget.compact ? 11 : 13))
                      ])))));
}

class ClayRocker extends StatelessWidget {
  const ClayRocker(
      {super.key, required this.title, required this.up, required this.down});
  final String title;
  final VoidCallback up, down;
  @override
  Widget build(BuildContext context) => ClayContainer(
      width: 58,
      height: 178,
      radius: 36,
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 5),
      child:
          Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        ClayButton(
            icon: Icons.add_rounded,
            iconOnly: true,
            compact: true,
            color: mint,
            onTap: up),
        Text(title,
            style: const TextStyle(color: mint, fontWeight: FontWeight.w900)),
        ClayButton(
            icon: Icons.remove_rounded,
            iconOnly: true,
            compact: true,
            color: mint,
            onTap: down)
      ]));
}
