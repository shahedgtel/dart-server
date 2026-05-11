import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final Pool pool;

String dbVal(dynamic value) {
  if (value == null) return 'NULL';
  if (value is num) return value.toString();
  if (value is bool) return value ? 'TRUE' : 'FALSE';
  if (value is DateTime) return "'${value.toIso8601String()}'";
  final str = value.toString();
  return "'${str.replaceAll("'", "''")}'";
}

Future<dynamic> parseBody(Request request) async {
  final content = await request.readAsString();
  return content.isNotEmpty ? jsonDecode(content) : {};
}

Object? dateSerializer(Object? item) {
  if (item is DateTime) return item.toIso8601String();
  return item;
}

int? safeInt(dynamic v) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');

double? safeDouble(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

String? safeStr(dynamic v) => v?.toString().trim();

DateTime? safeDate(dynamic v) =>
    v == null ? null : DateTime.tryParse(v.toString());

Middleware corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
        });
      }

      final response = await handler(request);

      return response.change(
        headers: {
          ...response.headers,
          'Access-Control-Allow-Origin': '*',
        },
      );
    };
  };
}

class ApiController {
  Future<Response> fetchProducts(Request request) async {
    try {
      final q = request.url.queryParameters;
      final page = safeInt(q['page']) ?? 1;
      final limit = safeInt(q['limit']) ?? 20;
      final search = q['search']?.trim() ?? '';
      final brand = q['brand']?.trim() ?? '';
      final sortByLoss = q['sort'] == 'loss';
      final offset = (page - 1) * limit;

      var conditions = '1=1';

      if (search.isNotEmpty) {
        final safeSearch = dbVal('%$search%');
        conditions +=
            ' AND (p.model ILIKE $safeSearch OR p.name ILIKE $safeSearch OR p.brand ILIKE $safeSearch)';
      }

      if (brand.isNotEmpty) {
        conditions += ' AND p.brand = ${dbVal(brand)}';
      }

      var orderBy = 'p.id DESC';

      if (sortByLoss) {
        orderBy =
            'LEAST(COALESCE(p.agent,0) - COALESCE(p.avg_purchase_price,0), COALESCE(p.wholesale,0) - COALESCE(p.avg_purchase_price,0)) ASC';
      }

      final results = await pool.runTx((session) async {
        final products = await session.execute('''
          SELECT
            p.*,
            COALESCE(
              json_agg(
                json_build_object(
                  'warehouse_id', w.id,
                  'warehouse_name', w.name,
                  'qty', pws.qty,
                  'location', pws.location
                )
                ORDER BY w.id ASC
              ) FILTER (WHERE pws.id IS NOT NULL),
              '[]'
            ) AS warehouse_stocks
          FROM products p
          LEFT JOIN product_warehouse_stock pws
            ON pws.product_id = p.id
          LEFT JOIN warehouses w
            ON w.id = pws.warehouse_id
          WHERE $conditions
          GROUP BY p.id
          ORDER BY $orderBy
          LIMIT $limit OFFSET $offset
        ''');

        final count = await session.execute(
          'SELECT COUNT(*)::int AS count FROM products p WHERE $conditions',
        );

        final totalValue = await session.execute('''
          SELECT SUM(
            (COALESCE(p.sea_stock_qty, 0) * COALESCE(p.sea, 0)) +
            (COALESCE(p.air_stock_qty, 0) * COALESCE(p.air, 0)) +
            (COALESCE(p.local_qty, 0) * COALESCE(p.avg_purchase_price, 0))
          )::float8 AS total_val
          FROM products p
          WHERE $conditions
        ''');

        return [products, count, totalValue];
      });

      return Response.ok(
        jsonEncode({
          'products': results[0].map((r) => r.toColumnMap()).toList(),
          'total': results[1].first.toColumnMap()['count'] ?? 0,
          'total_value': results[2].first.toColumnMap()['total_val'] ?? 0.0,
        }, toEncodable: dateSerializer),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> fetchShortList(Request request) async {
    try {
      final q = request.url.queryParameters;
      final search = q['search']?.trim() ?? '';

      var conditions = 'stock_qty <= alert_qty';

      if (search.isNotEmpty) {
        final safeSearch = dbVal('%$search%');
        conditions +=
            ' AND (model ILIKE $safeSearch OR name ILIKE $safeSearch)';
      }

      if (q['all'] == 'true') {
        final res = await pool.execute(
          'SELECT * FROM products WHERE $conditions ORDER BY stock_qty ASC',
        );

        return Response.ok(
          jsonEncode(
            {'products': res.map((r) => r.toColumnMap()).toList()},
            toEncodable: dateSerializer,
          ),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final page = safeInt(q['page']) ?? 1;
      final limit = safeInt(q['limit']) ?? 20;
      final offset = (page - 1) * limit;

      final results = await pool.runTx((session) async {
        final products = await session.execute(
          'SELECT * FROM products WHERE $conditions ORDER BY stock_qty ASC LIMIT $limit OFFSET $offset',
        );
        final count = await session.execute(
          'SELECT COUNT(*)::int AS count FROM products WHERE $conditions',
        );
        return [products, count];
      });

      return Response.ok(
        jsonEncode({
          'products': results[0].map((r) => r.toColumnMap()).toList(),
          'total': results[1].first.toColumnMap()['count'] ?? 0,
        }, toEncodable: dateSerializer),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> fetchWarehouses(Request request) async {
    try {
      final res = await pool.execute(
        'SELECT * FROM warehouses ORDER BY id ASC',
      );

      return Response.ok(
        jsonEncode({
          'warehouses': res.map((r) => r.toColumnMap()).toList(),
        }, toEncodable: dateSerializer),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> createWarehouse(Request request) async {
    try {
      final body = await parseBody(request);
      final name = safeStr(body['name']) ?? '';

      if (name.isEmpty) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Warehouse name is required'}),
        );
      }

      final res = await pool.execute(
        'INSERT INTO warehouses (name) VALUES (${dbVal(name)}) RETURNING id',
      );

      return Response.ok(jsonEncode({
        'success': true,
        'id': res.first.toColumnMap()['id'],
      }));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> updateWarehouse(Request request, String idStr) async {
    try {
      final id = int.parse(idStr);
      final body = await parseBody(request);
      final name = safeStr(body['name']) ?? '';
      final isActive = body['is_active'] == false ? false : true;

      if (name.isEmpty) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Warehouse name is required'}),
        );
      }

      await pool.execute('''
        UPDATE warehouses
        SET name = ${dbVal(name)}, is_active = ${dbVal(isActive)}
        WHERE id = $id
      ''');

      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> addSingleProduct(Request request) async {
    try {
      final body = await parseBody(request);
      final vals = _prepValues(body);

      final res = await pool.runTx((session) async {
        final insert = await session.execute('''
          INSERT INTO products (
            name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
            shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency,
            stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty, local_qty, alert_qty
          ) VALUES (
            ${vals['name']}, ${vals['category']}, ${vals['brand']}, ${vals['model']},
            ${vals['weight']}, ${vals['yuan']}, ${vals['sea']}, ${vals['air']},
            ${vals['agent']}, ${vals['wholesale']}, ${vals['shipmenttax']},
            ${vals['shipmenttaxair']}, ${vals['shipmentdate']}, ${vals['shipmentno']},
            ${vals['currency']}, ${vals['stock_qty']}, ${vals['avg_purchase_price']},
            ${vals['sea_stock_qty']}, ${vals['air_stock_qty']}, ${vals['local_qty']},
            ${vals['alert_qty']}
          ) RETURNING id
        ''');

        final productId = safeInt(insert.first.toColumnMap()['id']) ?? 0;
        final stockQty = safeInt(body['stock_qty']) ?? 0;

        if (stockQty > 0) {
          final warehouseId = await _getDefaultWarehouseId(session);
          await _upsertWarehouseStock(
            session: session,
            productId: productId,
            warehouseId: warehouseId,
            qty: stockQty,
            location: safeStr(body['warehouse_location']) ?? '',
          );
        }

        return productId;
      });

      return Response.ok(jsonEncode({'id': res}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> addStockMixed(Request request) async {
    try {
      return await _processAddStock(await parseBody(request));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> bulkAddStockMixed(Request request) async {
    try {
      final body = await parseBody(request);
      final items = body is List ? body : body['items'] as List? ?? [];

      var count = 0;

      for (final item in items) {
        await _processAddStock(Map<String, dynamic>.from(item));
        count++;
      }

      return Response.ok(jsonEncode({'success': true, 'processed': count}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> _processAddStock(Map<String, dynamic> p) async {
    final id = safeInt(p['id']) ?? 0;
    final incSea = safeInt(p['sea_qty']) ?? 0;
    final incAir = safeInt(p['air_qty']) ?? 0;
    final incLocal = safeInt(p['local_qty']) ?? 0;
    final localPrice = safeDouble(p['local_price']) ?? 0.0;
    final newShipDate = safeDate(p['shipmentdate']);
    final warehouseIdFromBody = safeInt(p['warehouse_id']);
    final warehouseLocation = safeStr(p['warehouse_location']) ?? '';

    final totalIncoming = incSea + incAir + incLocal;

    if (totalIncoming <= 0 && newShipDate == null) {
      return Response.ok(jsonEncode({'success': true, 'message': 'No changes'}));
    }

    return await pool.runTx((session) async {
      final res = await session.execute(
        'SELECT * FROM products WHERE id = $id FOR UPDATE',
      );

      if (res.isEmpty) {
        return Response.notFound(jsonEncode({'error': 'Product not found'}));
      }

      final row = res.first.toColumnMap();

      final oldQty = safeDouble(row['stock_qty']) ?? 0.0;
      final oldAvg = safeDouble(row['avg_purchase_price']) ?? 0.0;
      final yuan = safeDouble(row['yuan']) ?? 0.0;
      final curr = safeDouble(row['currency']) ?? 0.0;
      final weight = safeDouble(row['weight']) ?? 0.0;
      final tax = safeDouble(row['shipmenttax']) ?? 0.0;
      final taxAir = safeDouble(row['shipmenttaxair']) ?? 0.0;

      final seaUnitCost = (yuan * curr) + (weight * tax);
      final airUnitCost = (yuan * curr) + (weight * taxAir);

      final incomingValue =
          (incSea * seaUnitCost) + (incAir * airUnitCost) + (incLocal * localPrice);

      final oldValue = oldQty * oldAvg;
      final newTotalQty = oldQty + totalIncoming;
      final newAvg =
          newTotalQty > 0 ? (oldValue + incomingValue) / newTotalQty : 0.0;

      var setClause = '''
        stock_qty = COALESCE(stock_qty, 0) + $totalIncoming,
        sea_stock_qty = COALESCE(sea_stock_qty, 0) + $incSea,
        air_stock_qty = COALESCE(air_stock_qty, 0) + $incAir,
        local_qty = COALESCE(local_qty, 0) + $incLocal,
        avg_purchase_price = $newAvg
      ''';

      if (newShipDate != null) {
        setClause += ', shipmentdate = ${dbVal(newShipDate)}';
      }

      await session.execute('UPDATE products SET $setClause WHERE id = $id');

      final warehouseId =
          warehouseIdFromBody != null && warehouseIdFromBody > 0
              ? warehouseIdFromBody
              : await _getDefaultWarehouseId(session);

      await _upsertWarehouseStock(
        session: session,
        productId: id,
        warehouseId: warehouseId,
        qty: totalIncoming,
        location: warehouseLocation,
      );

      return Response.ok(jsonEncode({'success': true, 'new_avg': newAvg}));
    });
  }

  Future<Response> bulkUpdateStock(Request request) async {
    try {
      final body = await parseBody(request);
      final updates = body['updates'] as List? ?? [];

      await pool.runTx((session) async {
        for (final raw in updates) {
          final item = Map<String, dynamic>.from(raw);
          final qty = safeInt(item['qty']) ?? 0;
          final id = safeInt(item['id']) ?? 0;
          final warehouseId = safeInt(item['warehouse_id']);

          await session.execute('''
            UPDATE products SET
              stock_qty = GREATEST(0, COALESCE(stock_qty, 0) - $qty),
              local_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty
                ELSE 0
              END,
              air_stock_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty
                WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty
                  THEN air_stock_qty - ($qty - COALESCE(local_qty, 0))
                ELSE 0
              END,
              sea_stock_qty = CASE
                WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty THEN sea_stock_qty
                ELSE GREATEST(0, sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0))))
              END
            WHERE id = $id
          ''');

          await _deductWarehouseStock(
            session: session,
            productId: id,
            qty: qty,
            warehouseId: warehouseId,
          );
        }
      });

      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> recalculateAirSea(Request request) async {
    try {
      final p = await parseBody(request);
      final newCurr = safeDouble(p['currency']) ?? 0.0;

      if (newCurr <= 0) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid currency'}));
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
                    (COALESCE(sea_stock_qty, 0) * ((yuan * currency) + (weight * shipmenttax))) +
                    (COALESCE(air_stock_qty, 0) * ((yuan * currency) + (weight * shipmenttaxair)))
                  )
                )
                +
                (
                  (COALESCE(sea_stock_qty, 0) * ((yuan * $newCurr) + (weight * shipmenttax))) +
                  (COALESCE(air_stock_qty, 0) * ((yuan * $newCurr) + (weight * shipmenttaxair)))
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
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> updateProduct(Request request, String idStr) async {
    try {
      final id = int.parse(idStr);
      final vals = _prepValues(await parseBody(request));

      await pool.execute('''
        UPDATE products SET
          name=${vals['name']},
          category=${vals['category']},
          brand=${vals['brand']},
          model=${vals['model']},
          weight=${vals['weight']},
          yuan=${vals['yuan']},
          sea=${vals['sea']},
          air=${vals['air']},
          agent=${vals['agent']},
          wholesale=${vals['wholesale']},
          shipmenttax=${vals['shipmenttax']},
          shipmenttaxair=${vals['shipmenttaxair']},
          shipmentdate=${vals['shipmentdate']},
          shipmentno=${vals['shipmentno']},
          currency=${vals['currency']},
          stock_qty=${vals['stock_qty']},
          avg_purchase_price=${vals['avg_purchase_price']},
          sea_stock_qty=${vals['sea_stock_qty']},
          air_stock_qty=${vals['air_stock_qty']},
          local_qty=${vals['local_qty']},
          alert_qty=${vals['alert_qty']}
        WHERE id=$id
      ''');

      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> deleteProduct(Request request, String idStr) async {
    try {
      final id = int.parse(idStr);
      await pool.execute('DELETE FROM products WHERE id=$id');
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> addToService(Request request) async {
    try {
      final p = await parseBody(request);
      final pid = safeInt(p['product_id']) ?? 0;
      final qty = safeInt(p['qty']) ?? 0;
      final cost = safeDouble(p['current_avg_price']) ?? 0.0;
      final type = dbVal(safeStr(p['type']) ?? 'Repair');
      final model = dbVal(safeStr(p['model']) ?? '');
      final warehouseId = safeInt(p['warehouse_id']);

      return await pool.runTx((session) async {
        await session.execute('''
          UPDATE products SET
            stock_qty = GREATEST(0, COALESCE(stock_qty, 0) - $qty),
            local_qty = CASE
              WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty
              ELSE 0
            END,
            air_stock_qty = CASE
              WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty
              WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty
                THEN air_stock_qty - ($qty - COALESCE(local_qty, 0))
              ELSE 0
            END,
            sea_stock_qty = CASE
              WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty THEN sea_stock_qty
              ELSE GREATEST(0, sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0))))
            END
          WHERE id = $pid
        ''');

        await _deductWarehouseStock(
          session: session,
          productId: pid,
          qty: qty,
          warehouseId: warehouseId,
        );

        await session.execute('''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES ($pid, $model, $qty, $type, $cost)
        ''');

        return Response.ok(jsonEncode({'success': true}));
      });
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> returnFromService(Request request) async {
    try {
      final p = await parseBody(request);
      final logId = safeInt(p['log_id']) ?? 0;
      final qtyToReturn = safeInt(p['qty']) ?? 0;
      final warehouseIdFromBody = safeInt(p['warehouse_id']);
      final location = safeStr(p['warehouse_location']) ?? '';

      if (qtyToReturn <= 0) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid qty'}));
      }

      return await pool.runTx((session) async {
        final res = await session.execute(
          'SELECT * FROM product_logs WHERE id = $logId FOR UPDATE',
        );

        if (res.isEmpty) {
          return Response.notFound(jsonEncode({'error': 'Log not found'}));
        }

        final log = res.first.toColumnMap();

        if (log['status'] == 'returned') {
          return Response.badRequest(
            body: jsonEncode({'error': 'Already returned'}),
          );
        }

        final pid = safeInt(log['product_id']) ?? 0;
        final currentLogQty = safeInt(log['qty']) ?? 0;

        if (qtyToReturn > currentLogQty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'Cannot return. Limit exceeded.'}),
          );
        }

        await session.execute('''
          UPDATE products
          SET stock_qty = COALESCE(stock_qty, 0) + $qtyToReturn,
              local_qty = COALESCE(local_qty, 0) + $qtyToReturn
          WHERE id = $pid
        ''');

        final warehouseId =
            warehouseIdFromBody != null && warehouseIdFromBody > 0
                ? warehouseIdFromBody
                : await _getDefaultWarehouseId(session);

        await _upsertWarehouseStock(
          session: session,
          productId: pid,
          warehouseId: warehouseId,
          qty: qtyToReturn,
          location: location,
        );

        final remainingQty = currentLogQty - qtyToReturn;

        if (remainingQty == 0) {
          await session.execute(
            "UPDATE product_logs SET status = 'returned', qty = 0 WHERE id = $logId",
          );
        } else {
          await session.execute(
            'UPDATE product_logs SET qty = $remainingQty WHERE id = $logId',
          );
        }

        return Response.ok(jsonEncode({'success': true}));
      });
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> getServiceLogs(Request request) async {
    try {
      final res = await pool.execute(
        "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC",
      );

      return Response.ok(
        jsonEncode(
          {'data': res.map((r) => r.toColumnMap()).toList()},
          toEncodable: dateSerializer,
        ),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<int> _getDefaultWarehouseId(dynamic session) async {
    final found = await session.execute(
      'SELECT id FROM warehouses WHERE is_active = TRUE ORDER BY id ASC LIMIT 1',
    );

    if (found.isNotEmpty) {
      return safeInt(found.first.toColumnMap()['id']) ?? 1;
    }

    final created = await session.execute(
      "INSERT INTO warehouses (name) VALUES ('Main Warehouse') RETURNING id",
    );

    return safeInt(created.first.toColumnMap()['id']) ?? 1;
  }

  Future<void> _upsertWarehouseStock({
    required dynamic session,
    required int productId,
    required int warehouseId,
    required int qty,
    String location = '',
  }) async {
    if (qty <= 0) return;

    await session.execute('''
      INSERT INTO product_warehouse_stock (
        product_id, warehouse_id, qty, location, updated_at
      ) VALUES (
        $productId, $warehouseId, $qty, ${dbVal(location)}, NOW()
      )
      ON CONFLICT (product_id, warehouse_id)
      DO UPDATE SET
        qty = product_warehouse_stock.qty + EXCLUDED.qty,
        location = CASE
          WHEN EXCLUDED.location <> '' THEN EXCLUDED.location
          ELSE product_warehouse_stock.location
        END,
        updated_at = NOW()
    ''');
  }

  Future<void> _deductWarehouseStock({
    required dynamic session,
    required int productId,
    required int qty,
    int? warehouseId,
  }) async {
    if (qty <= 0) return;

    if (warehouseId != null && warehouseId > 0) {
      await session.execute('''
        UPDATE product_warehouse_stock
        SET qty = GREATEST(0, qty - $qty), updated_at = NOW()
        WHERE product_id = $productId AND warehouse_id = $warehouseId
      ''');
      return;
    }

    var remaining = qty;

    final rows = await session.execute('''
      SELECT id, qty
      FROM product_warehouse_stock
      WHERE product_id = $productId AND qty > 0
      ORDER BY warehouse_id ASC
      FOR UPDATE
    ''');

    for (final row in rows) {
      if (remaining <= 0) break;

      final data = row.toColumnMap();
      final rowId = safeInt(data['id']) ?? 0;
      final currentQty = safeInt(data['qty']) ?? 0;
      final take = currentQty >= remaining ? remaining : currentQty;

      await session.execute('''
        UPDATE product_warehouse_stock
        SET qty = qty - $take, updated_at = NOW()
        WHERE id = $rowId
      ''');

      remaining -= take;
    }
  }

  Map<String, String> _prepValues(Map<String, dynamic> p) {
    return {
      'name': dbVal(safeStr(p['name'])),
      'category': dbVal(safeStr(p['category'])),
      'brand': dbVal(safeStr(p['brand'])),
      'model': dbVal(safeStr(p['model'])),
      'weight': dbVal(safeDouble(p['weight'])),
      'yuan': dbVal(safeDouble(p['yuan'])),
      'sea': dbVal(safeDouble(p['sea'])),
      'air': dbVal(safeDouble(p['air'])),
      'agent': dbVal(safeDouble(p['agent'])),
      'wholesale': dbVal(safeDouble(p['wholesale'])),
      'shipmenttax': dbVal(safeDouble(p['shipmenttax'])),
      'shipmenttaxair': dbVal(safeDouble(p['shipmenttaxair']) ?? 0),
      'shipmentdate': dbVal(safeDate(p['shipmentdate'])),
      'shipmentno': dbVal(safeInt(p['shipmentno'])),
      'currency': dbVal(safeDouble(p['currency'])),
      'stock_qty': dbVal(safeInt(p['stock_qty']) ?? 0),
      'avg_purchase_price': dbVal(safeDouble(p['avg_purchase_price']) ?? 0),
      'sea_stock_qty': dbVal(safeInt(p['sea_stock_qty']) ?? 0),
      'air_stock_qty': dbVal(safeInt(p['air_stock_qty']) ?? 0),
      'local_qty': dbVal(safeInt(p['local_qty']) ?? 0),
      'alert_qty': dbVal(safeInt(p['alert_qty']) ?? 5),
    };
  }
}

void main() async {
  final dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
  final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '6543');
  final dbName = Platform.environment['DB_NAME'] ?? 'postgres';
  final dbUser = Platform.environment['DB_USER'] ?? 'postgres';
  final dbPass = Platform.environment['DB_PASS'] ?? '';
  final serverPort = int.parse(Platform.environment['PORT'] ?? '8080');

  pool = Pool.withEndpoints(
    [
      Endpoint(
        host: dbHost,
        port: dbPort,
        database: dbName,
        username: dbUser,
        password: dbPass,
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: 15,
      sslMode: SslMode.require,
      queryMode: QueryMode.simple,
    ),
  );

  final app = Router();
  final api = ApiController();

  app.get('/', (Request request) => Response.ok('Active'));

  app.get('/products', api.fetchProducts);
  app.get('/products/shortlist', api.fetchShortList);
  app.post('/products/add', api.addSingleProduct);
  app.post('/products/add-stock', api.addStockMixed);
  app.post('/products/bulk-add-stock', api.bulkAddStockMixed);
  app.put('/products/recalculate-prices', api.recalculateAirSea);
  app.put('/products/bulk-update-stock', api.bulkUpdateStock);
  app.put('/products/<id>', api.updateProduct);
  app.delete('/products/<id>', api.deleteProduct);

  app.get('/warehouses', api.fetchWarehouses);
  app.post('/warehouses', api.createWarehouse);
  app.put('/warehouses/<id>', api.updateWarehouse);

  app.post('/service/add', api.addToService);
  app.post('/service/return', api.returnFromService);
  app.get('/service/list', api.getServiceLogs);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler(app.call);

  Timer.periodic(const Duration(minutes: 2), (_) async {
    try {
      await pool.execute('SELECT 1');
    } catch (e) {
      print('Ping failed: $e');
    }
  });

  await shelf_io.serve(handler, '0.0.0.0', serverPort);
  print('Server running on port $serverPort');
}
