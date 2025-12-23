import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

/// ===============================
/// CORS
/// ===============================
Middleware corsMiddleware() {
  return (handler) {
    return (request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
        });
      }
      final res = await handler(request);
      return res.change(headers: {
        ...res.headers,
        'Access-Control-Allow-Origin': '*',
      });
    };
  };
}

/// ===============================
/// DB CONNECTION (PER REQUEST)
/// ===============================
Future<PostgreSQLConnection> openConnection() async {
  final conn = PostgreSQLConnection(
    Platform.environment['DB_HOST']!,
    int.parse(Platform.environment['DB_PORT'] ?? '6543'),
    Platform.environment['DB_NAME']!,
    username: Platform.environment['DB_USER'],
    password: Platform.environment['DB_PASS'],
    useSSL: true,
    timeoutInSeconds: 60,
  );

  await conn.open();
  return conn;
}

/// ===============================
/// SAFE HELPERS
/// ===============================
String esc(dynamic v) {
  if (v == null) return '';
  return v.toString().replaceAll("'", "''");
}

num numSafe(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v;
  return num.tryParse(v.toString()) ?? 0;
}

/// ===============================
/// BULK INSERT PRODUCTS
/// ===============================
Future<Response> insertProducts(Request request) async {
  PostgreSQLConnection? conn;
  try {
    conn = await openConnection();
    final body = await request.readAsString();
    final List list = jsonDecode(body);

    if (list.isEmpty) {
      return Response.badRequest(body: 'Empty list');
    }

    final values = list.map((p) {
      return '''
      (
        '${esc(p['name'])}',
        '${esc(p['category'])}',
        '${esc(p['brand'])}',
        '${esc(p['model'])}',
        ${numSafe(p['weight'])},
        ${numSafe(p['yuan'])},
        ${numSafe(p['sea'])},
        ${numSafe(p['air'])},
        ${numSafe(p['agent'])},
        ${numSafe(p['wholesale'])},
        ${numSafe(p['shipmentTax'])},
        ${numSafe(p['shipmentNo'])},
        ${numSafe(p['currency'])},
        ${numSafe(p['stock_qty'])}
      )
      ''';
    }).join(',');

    final sql = '''
    INSERT INTO products
    (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
    VALUES $values
    ''';

    await conn.execute(sql);

    return Response.ok(
      jsonEncode({'success': true, 'inserted': list.length}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  } finally {
    await conn?.close();
  }
}

/// ===============================
/// ADD SINGLE PRODUCT
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  PostgreSQLConnection? conn;
  try {
    conn = await openConnection();
    final p = jsonDecode(await request.readAsString());

    final sql = '''
    INSERT INTO products
    (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
    VALUES (
      '${esc(p['name'])}',
      '${esc(p['category'])}',
      '${esc(p['brand'])}',
      '${esc(p['model'])}',
      ${numSafe(p['weight'])},
      ${numSafe(p['yuan'])},
      ${numSafe(p['sea'])},
      ${numSafe(p['air'])},
      ${numSafe(p['agent'])},
      ${numSafe(p['wholesale'])},
      ${numSafe(p['shipmentTax'])},
      ${numSafe(p['shipmentNo'])},
      ${numSafe(p['currency'])},
      ${numSafe(p['stock_qty'])}
    )
    RETURNING id
    ''';

    final res = await conn.query(sql);

    return Response.ok(
      jsonEncode({'success': true, 'id': res.first[0]}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  } finally {
    await conn?.close();
  }
}

/// ===============================
/// UPDATE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  PostgreSQLConnection? conn;
  try {
    conn = await openConnection();
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());

    final sql = '''
    UPDATE products SET
      name='${esc(p['name'])}',
      category='${esc(p['category'])}',
      brand='${esc(p['brand'])}',
      model='${esc(p['model'])}',
      weight=${numSafe(p['weight'])},
      yuan=${numSafe(p['yuan'])},
      sea=${numSafe(p['sea'])},
      air=${numSafe(p['air'])},
      agent=${numSafe(p['agent'])},
      wholesale=${numSafe(p['wholesale'])},
      shipmentTax=${numSafe(p['shipmentTax'])},
      shipmentNo=${numSafe(p['shipmentNo'])},
      currency=${numSafe(p['currency'])},
      stock_qty=${numSafe(p['stock_qty'])}
    WHERE id=$id
    ''';

    final count = await conn.execute(sql);

    return Response.ok(
      jsonEncode({'success': true, 'updated': count}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  } finally {
    await conn?.close();
  }
}

/// ===============================
/// DELETE PRODUCT
/// ===============================
Future<Response> deleteProduct(Request request) async {
  PostgreSQLConnection? conn;
  try {
    conn = await openConnection();
    final id = int.parse(request.url.pathSegments.last);

    final count = await conn.execute(
      'DELETE FROM products WHERE id=$id',
    );

    return Response.ok(
      jsonEncode({'success': true, 'deleted': count}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  } finally {
    await conn?.close();
  }
}

/// ===============================
/// FETCH PRODUCTS
/// ===============================
Future<Response> fetchProducts(Request request) async {
  PostgreSQLConnection? conn;
  try {
    conn = await openConnection();
    final rows = await conn.query('SELECT * FROM products ORDER BY id');

    final data = rows.map((r) => {
      'id': r[0],
      'name': r[1],
      'category': r[2],
      'brand': r[3],
      'model': r[4],
      'weight': r[5],
      'yuan': r[6],
      'sea': r[7],
      'air': r[8],
      'agent': r[9],
      'wholesale': r[10],
      'shipmentTax': r[11],
      'shipmentNo': r[12],
      'currency': r[13],
      'stock_qty': r[14],
    }).toList();

    return Response.ok(
      jsonEncode(data),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  } finally {
    await conn?.close();
  }
}

/// ===============================
/// SERVER
/// ===============================
void main() async {
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler((req) {
    final path = req.url.path;

    if (path == 'products' && req.method == 'GET') return fetchProducts(req);
    if (path == 'products' && req.method == 'POST') return insertProducts(req);
    if (path == 'products/add' && req.method == 'POST') return addSingleProduct(req);
    if (path.startsWith('products/') && req.method == 'PUT') return updateProduct(req);
    if (path.startsWith('products/') && req.method == 'DELETE') return deleteProduct(req);

    return Response.notFound('Route not found');
  });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, '0.0.0.0', port);
  print('🚀 Server running on http://${server.address.address}:$port');
}
