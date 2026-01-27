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
/// 1. BULK INSERT (BATCHED)
/// ===============================
Future<Response> insertProducts(Request request) async {
  try {
    final List products = jsonDecode(await request.readAsString());
    
    const int batchSize = 50;

    for (var i = 0; i < products.length; i += batchSize) {
      final end = (i + batchSize < products.length) ? i + batchSize : products.length;
      final batch = products.sublist(i, end);

      await pool.runTx((session) async {
        for (final p in batch) {
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
          final vAlert = fmt(safeNum(p['alert_qty']) ?? 5);

          await session.execute('''
              INSERT INTO products (
                name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
                shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
                sea_stock_qty, air_stock_qty, local_qty, alert_qty
              ) VALUES (
                $vName, $vCat, $vBrand, $vModel, $vWeight, $vYuan, $vSea, $vAir, $vAgent, $vWholesale,
                $vTax, $vTaxAir, $vSDate::timestamp with time zone, $vSNo, $vCurr, $vStock, $vAvg, $vSStock, $vAStock, 0, $vAlert
              )
            ''');
        }
      });
      // Sleep slightly
      await Future.delayed(Duration(milliseconds: 100));
    }
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
    final vSDateSql =
        vSDate == null ? 'NULL' : "'$vSDate'::timestamp with time zone";
    final vSNo = fmt(safeNum(p['shipmentno']));
    final vCurr = fmt(safeNum(p['currency']));
    final vStock = fmt(safeNum(p['stock_qty']) ?? 0);
    final vAvg = fmt(safeNum(p['avg_purchase_price']) ?? 0);
    final vSStock = fmt(safeNum(p['sea_stock_qty']) ?? 0);
    final vAStock = fmt(safeNum(p['air_stock_qty']) ?? 0);
    final vAlert = fmt(safeNum(p['alert_qty']) ?? 5);

    final res = await pool.execute('''
        INSERT INTO products (
          name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
          shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
          sea_stock_qty, air_stock_qty, local_qty, alert_qty
        ) VALUES (
          $vName, $vCat, $vBrand, $vModel, $vWeight, $vYuan, $vSea, $vAir, $vAgent, $vWholesale,
          $vTax, $vTaxAir, $vSDateSql, $vSNo, $vCurr, $vStock, $vAvg, $vSStock, $vAStock, 0, $vAlert
        ) RETURNING id
      ''');
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
    final vSDateSql =
        vSDate == null ? 'NULL' : "'$vSDate'::timestamp with time zone";
    final vSNo = fmt(safeNum(p['shipmentno']));
    final vCurr = fmt(safeNum(p['currency']));
    final vStock = fmt(safeNum(p['stock_qty']));
    final vAvg = fmt(safeNum(p['avg_purchase_price']));
    final vSStock = fmt(safeNum(p['sea_stock_qty']));
    final vAStock = fmt(safeNum(p['air_stock_qty']));
    final vLocal = fmt(safeNum(p['local_qty']));
    final vAlert = fmt(safeNum(p['alert_qty']));

    await pool.execute('''
        UPDATE products SET
          name=$vName, category=$vCat, brand=$vBrand, model=$vModel, weight=$vWeight, yuan=$vYuan,
          sea=$vSea, air=$vAir, agent=$vAgent, wholesale=$vWholesale,
          shipmenttax=$vTax, shipmenttaxair=$vTaxAir, shipmentdate=$vSDateSql,
          shipmentno=$vSNo, currency=$vCurr, stock_qty=$vStock, avg_purchase_price=$vAvg,
          sea_stock_qty=$vSStock, air_stock_qty=$vAStock, local_qty=$vLocal,
          alert_qty=$vAlert
        WHERE id=$id
      ''');
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 4. ADD STOCK (MIXED) - SINGLE
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
          'SELECT stock_qty, avg_purchase_price, yuan, currency, weight, shipmenttax, shipmenttaxair FROM products WHERE id = $id');

      if (res.isEmpty) return Response.notFound('Product not found');
      final row = res.first.toColumnMap();

      final double oldQty = safeNum(row['stock_qty'])?.toDouble() ?? 0.0;
      final double oldAvg =
          safeNum(row['avg_purchase_price'])?.toDouble() ?? 0.0;
      final double yuan = safeNum(row['yuan'])?.toDouble() ?? 0.0;
      final double curr = safeNum(row['currency'])?.toDouble() ?? 0.0;
      final double weight = safeNum(row['weight'])?.toDouble() ?? 0.0;
      final double tax = safeNum(row['shipmenttax'])?.toDouble() ?? 0.0;
      final double taxAir = safeNum(row['shipmenttaxair'])?.toDouble() ?? 0.0;

      final double seaUnitCost = (yuan * curr) + (weight * tax);
      final double airUnitCost = (yuan * curr) + (weight * taxAir);

      final double totalValueIncoming = (incSea * seaUnitCost) +
          (incAir * airUnitCost) +
          (incLocal * localPrice);

      final double totalValueOld = oldQty * oldAvg;
      final double newTotalQty = oldQty + totalIncoming;

      final double newAvg = newTotalQty > 0
          ? (totalValueOld + totalValueIncoming) / newTotalQty
          : 0.0;

      await session.execute('''
          UPDATE products SET
            stock_qty = stock_qty + $totalIncoming,
            sea_stock_qty = sea_stock_qty + $incSea,
            air_stock_qty = air_stock_qty + $incAir,
            local_qty = COALESCE(local_qty, 0) + $incLocal,
            avg_purchase_price = $newAvg
          WHERE id = $id
        ''');

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
/// 4.5 BULK ADD STOCK (BATCHED)
/// ===============================
Future<Response> bulkAddStockMixed(Request request) async {
  try {
    final List updates = jsonDecode(await request.readAsString());
    if (updates.isEmpty) {
      return Response.badRequest(body: "No items to update");
    }

    const int batchSize = 50; 

    for (var i = 0; i < updates.length; i += batchSize) {
      final end = (i + batchSize < updates.length) ? i + batchSize : updates.length;
      final batch = updates.sublist(i, end);

      await pool.runTx((session) async {
        for (final p in batch) {
          final int id = safeNum(p['id'])?.toInt() ?? 0;
          final int incSea = safeNum(p['sea_qty'])?.toInt() ?? 0;
          final int incAir = safeNum(p['air_qty'])?.toInt() ?? 0;
          final int incLocal = safeNum(p['local_qty'])?.toInt() ?? 0;
          final double localPrice = safeNum(p['local_price'])?.toDouble() ?? 0.0;
          final String? sDateRaw = safeStr(p['shipmentdate']);
          final String sDateSql = sDateRaw == null
              ? 'shipmentdate'
              : "'$sDateRaw'::timestamp with time zone";

          final int totalIncoming = incSea + incAir + incLocal;
          if (id == 0) continue;

          final res = await session.execute(
              'SELECT stock_qty, avg_purchase_price, yuan, currency, weight, shipmenttax, shipmenttaxair FROM products WHERE id = $id');

          if (res.isEmpty) continue;
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

          final double totalValueIncoming = (incSea * seaUnitCost) +
              (incAir * airUnitCost) +
              (incLocal * localPrice);

          final double totalValueOld = oldQty * oldAvg;
          final double newTotalQty = oldQty + totalIncoming;

          final double newAvg = newTotalQty > 0
              ? (totalValueOld + totalValueIncoming) / newTotalQty
              : 0.0;

          await session.execute('''
              UPDATE products SET
                stock_qty = stock_qty + $totalIncoming,
                sea_stock_qty = sea_stock_qty + $incSea,
                air_stock_qty = air_stock_qty + $incAir,
                local_qty = COALESCE(local_qty, 0) + $incLocal,
                avg_purchase_price = $newAvg,
                shipmentdate = $sDateSql
              WHERE id = $id
            ''');
        }
      });
      
      // Pause to let CPU cool down and other requests pass
      await Future.delayed(Duration(milliseconds: 200));
    }

    return Response.ok(jsonEncode({'success': true, 'count': updates.length}));
  } catch (e) {
    return Response.internalServerError(body: "Bulk Add Error: ${e.toString()}");
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

    await pool.execute('''
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
      ''');
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 6. POS CHECKOUT (BATCHED TO PREVENT TIMEOUTS)
/// ===============================
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];

    // SETTINGS
    const int batchSize = 50; // Process 50 items at a time
    
    // Loop through the updates in chunks
    for (var i = 0; i < updates.length; i += batchSize) {
      final end = (i + batchSize < updates.length) ? i + batchSize : updates.length;
      final batch = updates.sublist(i, end);

      // Run a small transaction for just these 50 items
      await pool.runTx((session) async {
        for (final item in batch) {
          int qty = safeNum(item['qty'])?.toInt() ?? 0;
          int id = safeNum(item['id'])?.toInt() ?? 0;

          await session.execute('''
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
            ''');
        }
      });

      // CRITICAL: Pause for 200ms between batches to release the lock
      // and allow GET requests to access the database.
      await Future.delayed(Duration(milliseconds: 200));
    }

    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    print("Error in bulk update: $e"); // Log error to console
    return Response.internalServerError(body: e.toString());
  }
}
/// ===============================
/// 7. FETCH PRODUCTS (PAGINATED)
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    final q = request.url.queryParameters;
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final limit = int.tryParse(q['limit'] ?? '20') ?? 20;
    final search = q['search']?.trim() ?? '';
    final brand = q['brand']?.trim() ?? '';
    final offset = (page - 1) * limit;

    List<String> conditions = [];

    if (search.isNotEmpty) {
      final safeSearch = fmt('%$search%');
      conditions.add(
          "(model ILIKE $safeSearch OR name ILIKE $safeSearch OR brand ILIKE $safeSearch)");
    }

    if (brand.isNotEmpty) {
      conditions.add("brand = ${fmt(brand)}");
    }

    String where = "";
    if (conditions.isNotEmpty) {
      where = "WHERE " + conditions.join(" AND ");
    }

    final totalRes =
        await pool.execute("SELECT COUNT(*)::int FROM products $where");
    final int total = totalRes.first.toColumnMap()['count'] ?? 0;

    final valRes = await pool.execute('''
      SELECT SUM(
        (COALESCE(sea_stock_qty, 0) * COALESCE(sea, 0)) + 
        (COALESCE(air_stock_qty, 0) * COALESCE(air, 0)) + 
        (COALESCE(local_qty, 0) * COALESCE(avg_purchase_price, 0))
      )::float8 as total_val 
      FROM products $where
    ''');

    final double totalValue = valRes.first.toColumnMap()['total_val'] ?? 0.0;

    final results = await pool.execute(
        "SELECT * FROM products $where ORDER BY id DESC LIMIT $limit OFFSET $offset");

    final List<Map<String, dynamic>> list =
        results.map((r) => r.toColumnMap()).toList();

    return Response.ok(
      jsonEncode(
        {
          'products': list,
          'total': total,
          'total_value': totalValue,
        },
        toEncodable: dateSerializer,
      ),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(body: "Server Error: ${e.toString()}");
  }
}

/// ===============================
/// 7.5 FETCH SHORTLIST (PAGINATED + EXPORT)
/// ===============================
Future<Response> fetchShortList(Request request) async {
  try {
    final q = request.url.queryParameters;

    // A. EXPORT MODE: Return ALL data if 'all=true'
    if (q['all'] == 'true') {
      final results = await pool.execute(
          "SELECT * FROM products WHERE stock_qty <= alert_qty ORDER BY stock_qty ASC");
      final list = results.map((r) => r.toColumnMap()).toList();
      return Response.ok(
        jsonEncode(list, toEncodable: dateSerializer),
        headers: {'Content-Type': 'application/json'},
      );
    }

    // B. PAGINATION MODE
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final limit = int.tryParse(q['limit'] ?? '20') ?? 20;
    final offset = (page - 1) * limit;

    // 1. Get Total Count for Shortlist
    final totalRes = await pool.execute(
        "SELECT COUNT(*)::int FROM products WHERE stock_qty <= alert_qty");
    final int total = totalRes.first.toColumnMap()['count'] ?? 0;

    // 2. Get Paginated Data
    final results = await pool.execute(
        "SELECT * FROM products WHERE stock_qty <= alert_qty ORDER BY stock_qty ASC LIMIT $limit OFFSET $offset");

    final List<Map<String, dynamic>> list =
        results.map((r) => r.toColumnMap()).toList();

    return Response.ok(
      jsonEncode(
        {
          'products': list,
          'total': total,
        },
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
/// 9. SERVICE LOGIC
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
      await session.execute('''
          UPDATE products SET
            stock_qty = GREATEST(0, stock_qty - $qty),
            local_qty = CASE WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty ELSE 0 END,
            air_stock_qty = CASE WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN air_stock_qty - ($qty - COALESCE(local_qty, 0)) ELSE 0 END,
            sea_stock_qty = CASE WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN sea_stock_qty ELSE sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + air_stock_qty)) END
          WHERE id = $pid
        ''');

      await session.execute('''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES ($pid, $model, $qty, $type, $cost)
        ''');

      return Response.ok(jsonEncode({'success': true}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// B. Return from Service
Future<Response> returnFromService(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final int logId = safeNum(p['log_id'])?.toInt() ?? 0;
    final int qtyToReturn = safeNum(p['qty'])?.toInt() ?? 0;

    if (qtyToReturn <= 0) {
      return Response.badRequest(body: "Invalid return quantity");
    }

    return await pool.runTx((session) async {
      final res = await session
          .execute('SELECT * FROM product_logs WHERE id = $logId');
      if (res.isEmpty) return Response.notFound('Log not found');
      final log = res.first.toColumnMap();

      if (log['status'] == 'returned') {
        return Response.badRequest(body: 'This batch is already fully returned');
      }

      final int pid = safeNum(log['product_id'])?.toInt() ?? 0;
      final int currentLogQty = safeNum(log['qty'])?.toInt() ?? 0;

      if (qtyToReturn > currentLogQty) {
        return Response.badRequest(
            body: 'Cannot return $qtyToReturn. Only $currentLogQty in service.');
      }

      await session.execute(
          'UPDATE products SET stock_qty = stock_qty + $qtyToReturn, local_qty = COALESCE(local_qty, 0) + $qtyToReturn WHERE id = $pid');

      final int remainingQty = currentLogQty - qtyToReturn;

      if (remainingQty == 0) {
        await session.execute(
            "UPDATE product_logs SET status = 'returned', qty = 0 WHERE id = $logId");
      } else {
        await session.execute(
            "UPDATE product_logs SET qty = $remainingQty WHERE id = $logId");
      }

      return Response.ok(jsonEncode({'success': true}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// C. Get Logs
Future<Response> getServiceLogs(Request request) async {
  final res = await pool.execute(
      "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC");
  final list = res.map((r) => r.toColumnMap()).toList();

  return Response.ok(jsonEncode(list, toEncodable: dateSerializer));
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
  ],
      settings: PoolSettings(
          maxConnectionCount: 10,
          sslMode: SslMode.require,
          queryMode: QueryMode.simple));

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler((Request request) {
    final path = request.url.path;

    if (path == 'products' && request.method == 'GET') {
      return fetchProducts(request);
    }

    // ======================================
    // SHORTLIST ENDPOINT
    // ======================================
    if (path == 'products/shortlist' && request.method == 'GET') {
      return fetchShortList(request);
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
    if (path == 'products/bulk-add-stock' && request.method == 'POST') {
      return bulkAddStockMixed(request);
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
