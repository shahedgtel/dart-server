import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

late final Pool pool;

/// ===============================
/// HELPER: Formats values for SQL (Manual Security)
/// ===============================
String fmt(dynamic value) {
  if (value == null) return 'NULL';
  if (value is num) return value.toString(); // Numbers are safe
  if (value is DateTime) return "'${value.toIso8601String()}'"; // Dates need quotes
 
  // Strings: Escape single quotes to prevent SQL Injection
  String str = value.toString();
  return "'${str.replaceAll("'", "''")}'";
}

/// ===============================
/// HELPER: JSON DATE FIXER
/// ===============================
/// This function handles converting DateTime objects to Strings
/// automatically during jsonEncode.
Object? dateSerializer(Object? item) {
  if (item is DateTime) {
    return item.toIso8601String();
  }
  return item;
}

Middleware corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers':
                'Origin, Content-Type, Authorization',
          },
        );
      }
      final response = await handler(request);
      return response.change(
        headers: {...response.headers, 'Access-Control-Allow-Origin': '*'},
      );
    };
  };
}

num? safeNum(dynamic v) => v is num ? v : num.tryParse(v?.toString() ?? '');
String? safeStr(dynamic v) =>
    v?.toString().trim().isEmpty ?? true ? null : v.toString().trim();

/// ===============================
/// 1. BULK INSERT
/// ===============================
Future<Response> insertProducts(Request request) async {
  try {
    final List products = jsonDecode(await request.readAsString());
    await pool.runTx((session) async {
      for (final p in products) {
        final vName = fmt(safeStr(p['name']));
        final vCat = fmt(safeStr(p['category']));
        final vBrand = fmt(safeStr(p['brand']));
        final vModel = fmt(safeStr(p['model']));
        final vWeight = fmt(safeNum(p['weight']));
        final vYuan = fmt(safeNum(p['yuan']));
        final vSea = fmt(safeNum(p['sea']));
        final vAir = fmt(safeNum(p['air']));
        final vAgent = fmt(safeNum(p['agent']));
        final vWholesale = fmt(safeNum(p['wholesale']));
        final vTax = fmt(safeNum(p['shipmenttax']));
        final vTaxAir = fmt(safeNum(p['shipmenttaxair']) ?? 0);
        final vSDate = fmt(safeStr(p['shipmentdate']));
        final vSNo = fmt(safeNum(p['shipmentno']));
        final vCurr = fmt(safeNum(p['currency']));
        final vStock = fmt(safeNum(p['stock_qty']) ?? 0);
        final vAvg = fmt(safeNum(p['avg_purchase_price']) ?? 0);
        final vSStock = fmt(safeNum(p['sea_stock_qty']) ?? 0);
        final vAStock = fmt(safeNum(p['air_stock_qty']) ?? 0);

        await session.execute(
          '''
            INSERT INTO products (
              name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
              shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
              sea_stock_qty, air_stock_qty, local_qty
            ) VALUES (
              $vName, $vCat, $vBrand, $vModel, $vWeight, $vYuan, $vSea, $vAir, $vAgent, $vWholesale,
              $vTax, $vTaxAir, $vSDate::timestamp with time zone, $vSNo, $vCurr, $vStock, $vAvg, $vSStock, $vAStock, 0
            )
          '''
        );
      }
    });
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 2. ADD SINGLE PRODUCT
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
   
    final vName = fmt(safeStr(p['name']));
    final vCat = fmt(safeStr(p['category']));
    final vBrand = fmt(safeStr(p['brand']));
    final vModel = fmt(safeStr(p['model']));
    final vWeight = fmt(safeNum(p['weight']));
    final vYuan = fmt(safeNum(p['yuan']));
    final vSea = fmt(safeNum(p['sea']));
    final vAir = fmt(safeNum(p['air']));
    final vAgent = fmt(safeNum(p['agent']));
    final vWholesale = fmt(safeNum(p['wholesale']));
    final vTax = fmt(safeNum(p['shipmenttax']));
    final vTaxAir = fmt(safeNum(p['shipmenttaxair']) ?? 0);
    final vSDate = safeStr(p['shipmentdate']);
    final vSDateSql = vSDate == null ? 'NULL' : "'$vSDate'::timestamp with time zone";
    final vSNo = fmt(safeNum(p['shipmentno']));
    final vCurr = fmt(safeNum(p['currency']));
    final vStock = fmt(safeNum(p['stock_qty']) ?? 0);
    final vAvg = fmt(safeNum(p['avg_purchase_price']) ?? 0);
    final vSStock = fmt(safeNum(p['sea_stock_qty']) ?? 0);
    final vAStock = fmt(safeNum(p['air_stock_qty']) ?? 0);

    final res = await pool.execute(
      '''
        INSERT INTO products (
          name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
          shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
          sea_stock_qty, air_stock_qty, local_qty
        ) VALUES (
          $vName, $vCat, $vBrand, $vModel, $vWeight, $vYuan, $vSea, $vAir, $vAgent, $vWholesale,
          $vTax, $vTaxAir, $vSDateSql, $vSNo, $vCurr, $vStock, $vAvg, $vSStock, $vAStock, 0
        ) RETURNING id
      '''
    );
    return Response.ok(jsonEncode({'id': res.first.toColumnMap()['id']}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 3. UPDATE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  try {
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());

    final vName = fmt(safeStr(p['name']));
    final vCat = fmt(safeStr(p['category']));
    final vBrand = fmt(safeStr(p['brand']));
    final vModel = fmt(safeStr(p['model']));
    final vWeight = fmt(safeNum(p['weight']));
    final vYuan = fmt(safeNum(p['yuan']));
    final vSea = fmt(safeNum(p['sea']));
    final vAir = fmt(safeNum(p['air']));
    final vAgent = fmt(safeNum(p['agent']));
    final vWholesale = fmt(safeNum(p['wholesale']));
    final vTax = fmt(safeNum(p['shipmenttax']));
    final vTaxAir = fmt(safeNum(p['shipmenttaxair']));
    final vSDate = safeStr(p['shipmentdate']);
    final vSDateSql = vSDate == null ? 'NULL' : "'$vSDate'::timestamp with time zone";
    final vSNo = fmt(safeNum(p['shipmentno']));
    final vCurr = fmt(safeNum(p['currency']));
    final vStock = fmt(safeNum(p['stock_qty']));
    final vAvg = fmt(safeNum(p['avg_purchase_price']));
    final vSStock = fmt(safeNum(p['sea_stock_qty']));
    final vAStock = fmt(safeNum(p['air_stock_qty']));
    final vLocal = fmt(safeNum(p['local_qty']));

    await pool.execute(
      '''
        UPDATE products SET
          name=$vName, category=$vCat, brand=$vBrand, model=$vModel, weight=$vWeight, yuan=$vYuan,
          sea=$vSea, air=$vAir, agent=$vAgent, wholesale=$vWholesale,
          shipmenttax=$vTax, shipmenttaxair=$vTaxAir, shipmentdate=$vSDateSql,
          shipmentno=$vSNo, currency=$vCurr, stock_qty=$vStock, avg_purchase_price=$vAvg,
          sea_stock_qty=$vSStock, air_stock_qty=$vAStock, local_qty=$vLocal
        WHERE id=$id
      '''
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 4. ADD STOCK (MIXED)
/// ===============================
Future<Response> addStockMixed(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());

    final int id = safeNum(p['id'])?.toInt() ?? 0;
    final int incSea = safeNum(p['sea_qty'])?.toInt() ?? 0;
    final int incAir = safeNum(p['air_qty'])?.toInt() ?? 0;
    final int incLocal = safeNum(p['local_qty'])?.toInt() ?? 0;
    final double localPrice = safeNum(p['local_price'])?.toDouble() ?? 0.0;

    final int totalIncoming = incSea + incAir + incLocal;
    if (totalIncoming <= 0) return Response.badRequest(body: 'Qty must be > 0');

    return await pool.runTx((session) async {
      final res = await session.execute(
        'SELECT stock_qty, avg_purchase_price, yuan, currency, weight, shipmenttax, shipmenttaxair FROM products WHERE id = $id'
      );

      if (res.isEmpty) return Response.notFound('Product not found');
      final row = res.first.toColumnMap();

      final double oldQty = safeNum(row['stock_qty'])?.toDouble() ?? 0.0;
      final double oldAvg = safeNum(row['avg_purchase_price'])?.toDouble() ?? 0.0;
      final double yuan = safeNum(row['yuan'])?.toDouble() ?? 0.0;
      final double curr = safeNum(row['currency'])?.toDouble() ?? 0.0;
      final double weight = safeNum(row['weight'])?.toDouble() ?? 0.0;
      final double tax = safeNum(row['shipmenttax'])?.toDouble() ?? 0.0;
      final double taxAir = safeNum(row['shipmenttaxair'])?.toDouble() ?? 0.0;

      final double seaUnitCost = (yuan * curr) + (weight * tax);
      final double airUnitCost = (yuan * curr) + (weight * taxAir);

      final double totalValueIncoming =
          (incSea * seaUnitCost) +
          (incAir * airUnitCost) +
          (incLocal * localPrice);

      final double totalValueOld = oldQty * oldAvg;
      final double newTotalQty = oldQty + totalIncoming;

      final double newAvg = newTotalQty > 0
          ? (totalValueOld + totalValueIncoming) / newTotalQty
          : 0.0;

      await session.execute(
        '''
          UPDATE products SET
            stock_qty = stock_qty + $totalIncoming,
            sea_stock_qty = sea_stock_qty + $incSea,
            air_stock_qty = air_stock_qty + $incAir,
            local_qty = COALESCE(local_qty, 0) + $incLocal,
            avg_purchase_price = $newAvg
          WHERE id = $id
        '''
      );

      return Response.ok(
        jsonEncode({
          'success': true,
          'new_avg': newAvg,
          'added_total': totalIncoming,
        }),
      );
    });
  } catch (e) {
    return Response.internalServerError(body: "Server Error: ${e.toString()}");
  }
}

/// ===============================
/// 5. BULK CURRENCY UPDATE
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  try {
    final data = jsonDecode(await request.readAsString());
    final double newCurr = safeNum(data['currency'])?.toDouble() ?? 0.0;

    if (newCurr <= 0) {
      return Response.badRequest(body: 'Valid currency required');
    }

    await pool.execute(
      '''
        UPDATE products SET
          currency = $newCurr,

          avg_purchase_price = CASE
            WHEN stock_qty > 0 THEN
              (
                (
                  (stock_qty * avg_purchase_price) -
                  (
                    (sea_stock_qty * ((yuan * currency) + (weight * shipmenttax))) +
                    (air_stock_qty * ((yuan * currency) + (weight * shipmenttaxair)))
                  )
                )
                +
                (
                  (sea_stock_qty * ((yuan * $newCurr) + (weight * shipmenttax))) +
                  (air_stock_qty * ((yuan * $newCurr) + (weight * shipmenttaxair)))
                )
              ) / stock_qty
            ELSE 0
          END,

          sea = (yuan * $newCurr) + (weight * shipmenttax),
          air = (yuan * $newCurr) + (weight * shipmenttaxair)

        WHERE yuan > 0
      '''
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 6. POS CHECKOUT (WATERFALL)
/// ===============================
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];

    await pool.runTx((session) async {
      for (final item in updates) {
        int qty = safeNum(item['qty'])?.toInt() ?? 0;
        int id = safeNum(item['id'])?.toInt() ?? 0;

        await session.execute(
          '''
            UPDATE products SET
              stock_qty = GREATEST(0, stock_qty - $qty),
             
              local_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty
                ELSE 0
              END,

              air_stock_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN air_stock_qty - ($qty - COALESCE(local_qty, 0))
                ELSE 0
              END,

              sea_stock_qty = CASE
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN sea_stock_qty
                ELSE sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + air_stock_qty))
              END

            WHERE id = $id
          '''
        );
      }
    });
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 7. FETCH PRODUCTS (FIXED DATE CRASH)
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    final q = request.url.queryParameters;
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final limit = int.tryParse(q['limit'] ?? '20') ?? 20;
    final search = q['search']?.trim() ?? '';
    final offset = (page - 1) * limit;

    String where = "";
   
    if (search.isNotEmpty) {
      final safeSearch = fmt('%$search%');
      where = "WHERE model ILIKE $safeSearch OR name ILIKE $safeSearch OR brand ILIKE $safeSearch";
    }

    final totalRes = await pool.execute("SELECT COUNT(*)::int FROM products $where");
    final int total = totalRes.first.toColumnMap()['count'] ?? 0;

    final results = await pool.execute(
      "SELECT * FROM products $where ORDER BY id DESC LIMIT $limit OFFSET $offset"
    );

    final List<Map<String, dynamic>> list = results
        .map((r) => r.toColumnMap())
        .toList();

    return Response.ok(
      // CRITICAL FIX: Add toEncodable to handle DateTime -> String conversion
      jsonEncode(
        {'products': list, 'total': total},
        toEncodable: dateSerializer,
      ),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(body: "Server Error: ${e.toString()}");
  }
}

/// ===============================
/// 8. DELETE
/// ===============================
Future<Response> deleteProduct(Request request) async {
  try {
    final id = int.parse(request.url.pathSegments.last);
    await pool.execute('DELETE FROM products WHERE id=$id');
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 9. SERVICE LOGIC (FIXED DATE CRASH)
/// ===============================

// A. Move to Service
Future<Response> addToService(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final int pid = safeNum(p['product_id'])?.toInt() ?? 0;
    final int qty = safeNum(p['qty'])?.toInt() ?? 0;
    final double cost = safeNum(p['current_avg_price'])?.toDouble() ?? 0.0;
    final String type = fmt(p['type']);
    final String model = fmt(p['model']);

    return await pool.runTx((session) async {
      await session.execute(
        '''
          UPDATE products SET
            stock_qty = GREATEST(0, stock_qty - $qty),
            local_qty = CASE WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty ELSE 0 END,
            air_stock_qty = CASE WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN air_stock_qty - ($qty - COALESCE(local_qty, 0)) ELSE 0 END,
            sea_stock_qty = CASE WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN sea_stock_qty ELSE sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + air_stock_qty)) END
          WHERE id = $pid
        '''
      );

      await session.execute(
        '''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES ($pid, $model, $qty, $type, $cost)
        '''
      );

      return Response.ok(jsonEncode({'success': true}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// ===============================
// B. Return from Service (FIXED PARTIAL LOGIC)
// ===============================
Future<Response> returnFromService(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final int logId = safeNum(p['log_id'])?.toInt() ?? 0;
    
    // 1. READ REQUEST QTY (The fix)
    final int qtyToReturn = safeNum(p['qty'])?.toInt() ?? 0; 

    if (qtyToReturn <= 0) {
      return Response.badRequest(body: "Invalid return quantity");
    }

    return await pool.runTx((session) async {
      // Get current log data
      final res = await session.execute('SELECT * FROM product_logs WHERE id = $logId');
      if (res.isEmpty) return Response.notFound('Log not found');
      final log = res.first.toColumnMap();

      if (log['status'] == 'returned') {
        return Response.badRequest(body: 'This batch is already fully returned');
      }

      final int pid = safeNum(log['product_id'])?.toInt() ?? 0;
      final int currentLogQty = safeNum(log['qty'])?.toInt() ?? 0;

      // 2. VALIDATE: Ensure we don't return more than exists in service
      if (qtyToReturn > currentLogQty) {
        return Response.badRequest(body: 'Cannot return $qtyToReturn. Only $currentLogQty in service.');
      }

      // 3. UPDATE PRODUCT STOCK (Add back only the returned amount)
      await session.execute(
        'UPDATE products SET stock_qty = stock_qty + $qtyToReturn, local_qty = COALESCE(local_qty, 0) + $qtyToReturn WHERE id = $pid'
      );

      // 4. UPDATE LOG STATUS
      final int remainingQty = currentLogQty - qtyToReturn;

      if (remainingQty == 0) {
        // Full Return: Mark as returned and set qty to 0
        await session.execute("UPDATE product_logs SET status = 'returned', qty = 0 WHERE id = $logId");
      } else {
        // Partial Return: Reduce the qty in the log, keep status 'active'
        await session.execute("UPDATE product_logs SET qty = $remainingQty WHERE id = $logId");
      }

      return Response.ok(jsonEncode({'success': true}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// C. Get Logs (FIXED DATE CRASH)
Future<Response> getServiceLogs(Request request) async {
  final res = await pool.execute(
    "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC"
  );
  final list = res.map((r) => r.toColumnMap()).toList();
 
  // CRITICAL FIX: Use toEncodable here as well
  return Response.ok(
    jsonEncode(list, toEncodable: dateSerializer)
  );
}

/// ===============================
/// MAIN
/// ===============================
void main() async {
  pool = Pool.withEndpoints([
    Endpoint(
      host: Platform.environment['DB_HOST'] ?? 'localhost',
      port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
      database: Platform.environment['DB_NAME']!,
      username: Platform.environment['DB_USER']!,
      password: Platform.environment['DB_PASS']!,
    ),
  ], settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: SslMode.require,
      queryMode: QueryMode.simple
  ));

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler((Request request) {
        final path = request.url.path;
        if (path == 'products' && request.method == 'GET') {
          return fetchProducts(request);
        }
        if (path == 'products' && request.method == 'POST') {
          return insertProducts(request);
        }
        if (path == 'products/add' && request.method == 'POST') {
          return addSingleProduct(request);
        }
        if (path == 'products/add-stock' && request.method == 'POST') {
          return addStockMixed(request);
        }
        if (path == 'products/recalculate-prices' && request.method == 'PUT') {
          return recalculateAirSea(request);
        }
        if (path == 'products/bulk-update-stock' && request.method == 'PUT') {
          return bulkUpdateStock(request);
        }
        if (path.startsWith('products/') && request.method == 'PUT') {
          return updateProduct(request);
        }
        if (path.startsWith('products/') && request.method == 'DELETE') {
          return deleteProduct(request);
        }

        if (path == 'service/add' && request.method == 'POST') {
          return addToService(request);
        }
        if (path == 'service/return' && request.method == 'POST') {
          return returnFromService(request);
        }
        if (path == 'service/list' && request.method == 'GET') {
          return getServiceLogs(request);
        }

        return Response.notFound('Route not found');
      });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await shelf_io.serve(handler, '0.0.0.0', port);
  print('🚀 Server running on port $port');
}
