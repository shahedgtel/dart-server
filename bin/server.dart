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
Future<Connection> openConnection() async {
  final conn = await Connection.open(
    Endpoint(
      host: Platform.environment['DB_HOST']!,
      port: int.parse(Platform.environment['DB_PORT'] ?? '6543'),
      database: Platform.environment['DB_NAME']!,
      username: Platform.environment['DB_USER'],
      password: Platform.environment['DB_PASS'],
    ),
    settings: ConnectionSettings(
      sslMode: SslMode.require,
      connectTimeout: const Duration(seconds: 60),
    ),
  );

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
  Connection? conn;
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
  Connection? conn;
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
    ''';

    await conn.execute(sql);

    return Response.ok(
      jsonEncode({'success': true}),
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
  Connection? conn;
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
/// BULK UPDATE CURRENCY
/// ===============================
Future<Response> bulkUpdateCurrency(Request request) async {
  Connection? conn;
  try {
    conn = await openConnection();

    final body = jsonDecode(await request.readAsString());
    final currency = numSafe(body['currency']);

    final count =
        await conn.execute('UPDATE products SET currency=$currency');

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
  Connection? conn;
  try {
    conn = await openConnection();

    final id = int.parse(request.url.pathSegments.last);
    final count =
        await conn.execute('DELETE FROM products WHERE id=$id');

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
/// FETCH PRODUCTS (SAFE – NO PREPARE)
/// ===============================
Future<Response> fetchProducts(Request request) async {
  Connection? conn;
  try {
    conn = await openConnection();

    final result =
        await conn.execute('SELECT * FROM products ORDER BY id');

    final data = result.map((row) => row.toColumnMap()).toList();

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

    if (path == 'products' && req.method == 'GET') {
      return fetchProducts(req);
    }

    if (path == 'products' && req.method == 'POST') {
      return insertProducts(req);
    }

    if (path == 'products/add' && req.method == 'POST') {
      return addSingleProduct(req);
    }

    if (path == 'products/currency' && req.method == 'PUT') {
      return bulkUpdateCurrency(req);
    }

    if (path.startsWith('products/') && req.method == 'PUT') {
      return updateProduct(req);
    }

    if (path.startsWith('products/') && req.method == 'DELETE') {
      return deleteProduct(req);
    }

    return Response.notFound('Route not found');
  });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server =
      await shelf_io.serve(handler, '0.0.0.0', port);

  print('🚀 Server running on http://${server.address.address}:$port');
}
