import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'push_notifications.dart';
import 'staff_api.dart';

const _navy = Color(0xFF13271F);
const _green = Color(0xFF1F7051);
const _paper = Color(0xFFF5F6F2);
const _tokenKey = 'staff_app_access_token';
const _pushPreferencePrefix = 'staff_app_push_enabled_';
const _pushEndpointPrefix = 'staff_app_push_endpoint_';
const _pollInterval = Duration(seconds: 8);

class StaffNotificationsApp extends StatefulWidget {
  StaffNotificationsApp({super.key, StaffApi? api}) : _api = api ?? StaffApi();

  final StaffApi _api;

  @override
  State<StaffNotificationsApp> createState() => _StaffNotificationsAppState();
}

class _StaffNotificationsAppState extends State<StaffNotificationsApp> {
  String? _token;
  Map<String, dynamic>? _staff;
  List<Map<String, dynamic>> _notifications = [];
  Timer? _pollTimer;
  bool _loading = true;
  bool _loggingIn = false;
  bool _loadingNotifications = false;
  bool _pushBusy = false;
  bool _pushEnabled = false;
  String? _error;
  String _filter = 'All';
  Set<String> _knownNotificationIds = {};

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  StaffApi get _api => widget._api;

  Future<void> _restoreSession() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedToken = preferences.getString(_tokenKey);
      if (savedToken != null && savedToken.isNotEmpty) {
        final staff = await _api.session(savedToken);
        final username = staff['username']?.toString() ?? '';
        if (!mounted) return;
        setState(() {
          _token = savedToken;
          _staff = staff;
          _pushEnabled =
              username.isNotEmpty &&
              (preferences.getBool(_pushPreferenceKey(username)) ?? false);
          _loading = false;
        });
        await _refreshNotifications(initial: true);
        _startPolling();
        return;
      }
    } on StaffApiException {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_tokenKey);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = 'Unable to connect to the staff service. $error',
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _login(String username, String password) async {
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      final result = await _api.login(username, password);
      final token = result['access_token'] as String?;
      if (token == null || token.isEmpty) {
        throw const StaffApiException(
          'The staff service did not issue a sign-in token.',
        );
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_tokenKey, token);
      final staffUsername = result['username']?.toString() ?? username;
      if (!mounted) return;
      setState(() {
        _token = token;
        _staff = result;
        _pushEnabled =
            preferences.getBool(_pushPreferenceKey(staffUsername)) ?? false;
        _loggingIn = false;
      });
      await _refreshNotifications(initial: true);
      _startPolling();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _errorMessage(error);
          _loggingIn = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    final token = _token;
    final username = _staff?['username']?.toString() ?? '';
    _pollTimer?.cancel();
    final errors = <String>[];
    final preferences = await SharedPreferences.getInstance();
    final endpoint = username.isEmpty
        ? null
        : preferences.getString(_pushEndpointKey(username));
    if (token != null) {
      if (endpoint != null && endpoint.isNotEmpty) {
        try {
          await _api.removePushSubscription(token, endpoint);
        } catch (error) {
          errors.add(
            'Could not disable this device’s push subscription: ${_errorMessage(error)}',
          );
        }
      }
      try {
        await _api.logout(token);
      } catch (error) {
        errors.add('Server sign-out failed: ${_errorMessage(error)}');
      }
    }
    await preferences.remove(_tokenKey);
    if (username.isNotEmpty) {
      await preferences.remove(_pushPreferenceKey(username));
      await preferences.remove(_pushEndpointKey(username));
    }
    if (!mounted) return;
    setState(() {
      _token = null;
      _staff = null;
      _notifications = [];
      _knownNotificationIds = {};
      _pushEnabled = false;
      _error = errors.isEmpty
          ? null
          : 'Signed out on this device. ${errors.join(' ')}';
      _loading = false;
    });
  }

  Future<void> _refreshNotifications({bool initial = false}) async {
    final token = _token;
    if (token == null || _loadingNotifications) return;
    _loadingNotifications = true;
    try {
      final notifications = await _api.notifications(token);
      if (!mounted) return;
      final ids = notifications.map(_notificationId).toSet();
      final newItems = initial
          ? <Map<String, dynamic>>[]
          : notifications
                .where(
                  (item) =>
                      !_knownNotificationIds.contains(_notificationId(item)),
                )
                .toList();
      setState(() {
        _notifications = notifications;
        _knownNotificationIds = ids;
        _error = null;
      });
      for (final item in newItems) {
        _notifyWhileOpen(item);
      }
    } on StaffApiException catch (error) {
      if (error.message.contains('expired') ||
          error.message.contains('sign-in')) {
        await _logout();
      } else if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      _loadingNotifications = false;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _refreshNotifications());
  }

  String _notificationId(Map<String, dynamic> item) =>
      item['id']?.toString() ?? '${item['type']}-${item['created_at']}';

  void _notifyWhileOpen(Map<String, dynamic> item) {
    final title = item['title']?.toString() ?? 'New staff notification';
    final body = item['room']?.toString() ?? '';
    showForegroundNotification(title, body);
  }

  Future<void> _enablePush() async {
    final token = _token;
    final publicKey = _staff?['push_public_key']?.toString() ?? '';
    if (token == null) return;
    if (publicKey.isEmpty) {
      setState(
        () => _error = 'Push notifications are not configured for this hotel.',
      );
      return;
    }
    setState(() {
      _pushBusy = true;
      _error = null;
    });
    try {
      final subscription = await createPushSubscription(publicKey);
      final endpoint = subscription['endpoint'];
      final username = _staff?['username']?.toString() ?? '';
      if (endpoint is! String || endpoint.isEmpty || username.isEmpty) {
        throw const StaffApiException(
          'The browser returned an incomplete push subscription.',
        );
      }
      await _api.savePushSubscription(token, subscription);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_pushEndpointKey(username), endpoint);
      await preferences.setBool(_pushPreferenceKey(username), true);
      if (mounted) {
        setState(() {
          _pushEnabled = true;
          _error = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Staff notifications are enabled on this device.'),
          ),
        );
      }
    } on StaffApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _pushBusy = false);
    }
  }

  String _errorMessage(Object error) {
    if (error is StaffApiException) return error.message;
    if (error is StateError) {
      return error.message;
    }
    if (error is UnsupportedError) {
      return error.message ??
          'This browser does not support the requested feature.';
    }
    if (error is FormatException) {
      return error.message;
    }
    return 'Connection problem. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haidware Staff Inbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(seedColor: _green),
        fontFamily: 'Roboto',
      ),
      home: _loading
          ? const _LoadingScreen()
          : _token == null
          ? _LoginScreen(busy: _loggingIn, error: _error, onLogin: _login)
          : _InboxScreen(
              staff: _staff ?? const {},
              notifications: _filteredNotifications,
              totalCount: _notifications.length,
              pushEnabled: _pushEnabled,
              filter: _filter,
              error: _error,
              loading: _loadingNotifications,
              pushBusy: _pushBusy,
              onFilterChanged: (filter) => setState(() => _filter = filter),
              onRefresh: () => _refreshNotifications(),
              onEnablePush: _enablePush,
              onLogout: _logout,
            ),
    );
  }

  List<Map<String, dynamic>> get _filteredNotifications {
    if (_filter == 'All') return _notifications;
    final type = _filter == 'Orders' ? 'order' : 'service';
    return _notifications.where((item) => item['type'] == type).toList();
  }

  String _pushPreferenceKey(String username) =>
      '$_pushPreferencePrefix$username';

  String _pushEndpointKey(String username) => '$_pushEndpointPrefix$username';
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: _navy,
    body: Center(child: CircularProgressIndicator(color: Colors.white)),
  );
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({
    required this.busy,
    required this.error,
    required this.onLogin,
  });

  final bool busy;
  final String? error;
  final Future<void> Function(String username, String password) onLogin;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      widget.onLogin(_usernameController.text.trim(), _passwordController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Card(
                color: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(30),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _BrandMark(),
                        const SizedBox(height: 26),
                        Text(
                          'Staff sign in',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: _navy,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          'Use the username and password provided by your manager.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: const Color(0xFF66736C)),
                        ),
                        const SizedBox(height: 26),
                        TextFormField(
                          controller: _usernameController,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          decoration: _inputDecoration(
                            'Staff username',
                            Icons.person_outline,
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Enter your staff username.'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          autofillHints: const [AutofillHints.password],
                          onFieldSubmitted: (_) => _submit(),
                          decoration:
                              _inputDecoration(
                                'Password',
                                Icons.lock_outline,
                              ).copyWith(
                                suffixIcon: IconButton(
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                          validator: (value) => value == null || value.isEmpty
                              ? 'Enter your password.'
                              : null,
                        ),
                        if (widget.error != null) ...[
                          const SizedBox(height: 14),
                          _ErrorBanner(message: widget.error!),
                        ],
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: widget.busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: _green,
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: widget.busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Sign in to inbox'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InboxScreen extends StatelessWidget {
  const _InboxScreen({
    required this.staff,
    required this.notifications,
    required this.totalCount,
    required this.pushEnabled,
    required this.filter,
    required this.error,
    required this.loading,
    required this.pushBusy,
    required this.onFilterChanged,
    required this.onRefresh,
    required this.onEnablePush,
    required this.onLogout,
  });

  final Map<String, dynamic> staff;
  final List<Map<String, dynamic>> notifications;
  final int totalCount;
  final bool pushEnabled;
  final String filter;
  final String? error;
  final bool loading;
  final bool pushBusy;
  final ValueChanged<String> onFilterChanged;
  final VoidCallback onRefresh;
  final VoidCallback onEnablePush;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        titleSpacing: 20,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.room_service_outlined, size: 23),
            SizedBox(width: 10),
            Text(
              'HAIDWARE',
              style: TextStyle(
                letterSpacing: 2,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh inbox',
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: onLogout,
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              children: [
                _WelcomeCard(staff: staff, count: totalCount),
                if (!pushEnabled) ...[
                  const SizedBox(height: 16),
                  _PushPrompt(busy: pushBusy, onEnable: onEnablePush),
                ],
                if (error != null) ...[
                  const SizedBox(height: 16),
                  _ErrorBanner(message: error!),
                ],
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Notifications',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: _navy,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    if (loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: ['All', 'Orders', 'Services'].map((value) {
                    return ChoiceChip(
                      label: Text(value),
                      selected: filter == value,
                      onSelected: (_) => onFilterChanged(value),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                if (notifications.isEmpty)
                  const _EmptyInbox()
                else
                  ...notifications.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _NotificationCard(notification: item),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({required this.staff, required this.count});

  final Map<String, dynamic> staff;
  final int count;

  @override
  Widget build(BuildContext context) {
    final name = staff['name']?.toString() ?? 'Staff member';
    final department = staff['department']?.toString() ?? 'Hotel team';
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _navy,
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [_navy, Color(0xFF285341)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Good to have you, $name',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '$department  ·  Your assigned guest requests, in one place.',
                  style: const TextStyle(color: Color(0xFFD4E4DB)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Container(
            width: 68,
            height: 68,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text(
                  'NEW',
                  style: TextStyle(
                    color: Color(0xFFD4E4DB),
                    fontSize: 9,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PushPrompt extends StatelessWidget {
  const _PushPrompt({required this.busy, required this.onEnable});

  final bool busy;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F2ED),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_active_outlined, color: _green),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Get new order and service alerts, even when this app is closed.',
              style: TextStyle(color: _navy),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: busy ? null : onEnable,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Enable'),
          ),
        ],
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.notification});

  final Map<String, dynamic> notification;

  @override
  Widget build(BuildContext context) {
    final isOrder = notification['type'] == 'order';
    final items = notification['items'] is List
        ? (notification['items'] as List)
        : const [];
    final createdAt = DateTime.tryParse(
      notification['created_at']?.toString() ?? '',
    );
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE6EAE6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9F2ED),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    isOrder ? Icons.receipt_long_outlined : Icons.room_service,
                    color: _green,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notification['title']?.toString() ??
                            'Guest notification',
                        style: const TextStyle(
                          color: _navy,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          notification['department'],
                          notification['room'] == null
                              ? null
                              : 'Room ${notification['room']}',
                          createdAt == null ? null : _formatDate(createdAt),
                        ].whereType<String>().join('  ·  '),
                        style: const TextStyle(
                          color: Color(0xFF738078),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusPill(
                  status: notification['status']?.toString() ?? 'New',
                ),
              ],
            ),
            if (notification['sender_name']?.toString().isNotEmpty == true) ...[
              const SizedBox(height: 14),
              Text(
                'Guest: ${notification['sender_name']}',
                style: const TextStyle(color: Color(0xFF56645C)),
              ),
            ],
            if (items.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: items.map((item) {
                  if (item is! Map) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: _paper,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '${item['quantity']} × ${item['name']}',
                      style: const TextStyle(color: _navy, fontSize: 13),
                    ),
                  );
                }).toList(),
              ),
            ],
            if (notification['details']?.toString().isNotEmpty == true) ...[
              const SizedBox(height: 12),
              Text(
                notification['details'].toString(),
                style: const TextStyle(color: Color(0xFF56645C)),
              ),
            ],
            if (isOrder && notification['total'] != null) ...[
              const SizedBox(height: 14),
              Text(
                'Total: ${notification['total']}',
                style: const TextStyle(
                  color: _navy,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F2EE),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        status,
        style: const TextStyle(
          color: Color(0xFF58635D),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE6EAE6)),
    ),
    child: const Column(
      children: [
        Icon(Icons.inbox_outlined, size: 38, color: Color(0xFF87938B)),
        SizedBox(height: 12),
        Text(
          'You’re all caught up',
          style: TextStyle(
            color: _navy,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'New orders and service requests assigned to you will appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF738078)),
        ),
      ],
    ),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 45,
        height: 45,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _green,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.room_service_outlined, color: Colors.white),
      ),
      const SizedBox(width: 12),
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HAIDWARE',
            style: TextStyle(
              color: _navy,
              fontSize: 13,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 3),
          Text(
            'STAFF INBOX',
            style: TextStyle(
              color: Color(0xFF78837D),
              fontSize: 10,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    ],
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFFFEFEB),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, color: Color(0xFF9A3D2D), size: 20),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: Color(0xFF7C3326)),
          ),
        ),
      ],
    ),
  );
}

InputDecoration _inputDecoration(String label, IconData icon) =>
    InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: const Color(0xFFF5F6F2),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
    );

String _formatDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${local.day}/${local.month} $hour:$minute $period';
}
