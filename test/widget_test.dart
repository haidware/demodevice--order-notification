import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:demodevice_order_notification/notifications_app.dart';
import 'package:demodevice_order_notification/staff_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('staff can sign in and see assigned guest orders', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = StaffApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/staff/app/login/')) {
          expect(jsonDecode(request.body), {
            'username': 'kemi',
            'password': 'manager-password',
          });
          return http.Response(
            jsonEncode({
              'access_token': 'staff-access-token',
              'name': 'Kemi',
              'username': 'kemi',
              'department': 'Kitchen',
              'push_enabled': true,
              'push_public_key': 'public-key',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/staff/app/notifications/')) {
          expect(request.headers['authorization'], 'Bearer staff-access-token');
          return http.Response(
            jsonEncode({
              'notifications': [
                {
                  'id': 42,
                  'type': 'order',
                  'title': 'New Kitchen order',
                  'department': 'Kitchen',
                  'room': '212',
                  'sender_name': 'Jane',
                  'items': [
                    {'name': 'Jollof Rice', 'quantity': 1},
                  ],
                  'status': 'Pending',
                  'total': '5000.00',
                  'created_at': '2026-03-01T10:00:00Z',
                },
              ],
            }),
            200,
          );
        }
        fail('Unexpected API request: ${request.method} ${request.url}');
      }),
    );

    await tester.pumpWidget(StaffNotificationsApp(api: api));
    await tester.pumpAndSettle();

    expect(find.text('Staff sign in'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), 'kemi');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'manager-password',
    );
    await tester.tap(find.text('Sign in to inbox'));
    await tester.pumpAndSettle();

    expect(find.text('Good to have you, Kemi'), findsOneWidget);
    expect(
      find.text(
        'Get new order and service alerts, even when this app is closed.',
      ),
      findsOneWidget,
    );
    expect(find.text('New Kitchen order'), findsOneWidget);
    expect(find.textContaining('Room 212'), findsOneWidget);
    expect(find.text('1 × Jollof Rice'), findsOneWidget);
  });
}
