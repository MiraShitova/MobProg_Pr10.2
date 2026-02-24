import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:developer' as developer;



class Order {
  final int? id;
  final int userId;
  final double totalAmount;
  final String status;
  final DateTime createdAt;

  Order({
    this.id,
    required this.userId,
    required this.totalAmount,
    required this.status,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'userId': userId,
      'totalAmount': totalAmount,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
    };
  }

    @override
  String toString() {
    return 'Order{id: $id, userId: $userId, totalAmount: $totalAmount, status: $status, createdAt: $createdAt}';
  }
}

class OrderItem {
  final int? id;
  final int orderId;
  final int productId;
  final int quantity;
  final double price;

  OrderItem({
    this.id,
    required this.orderId,
    required this.productId,
    required this.quantity,
    required this.price,
  });

   Map<String, dynamic> toMap() {
    return {
      'id': id,
      'orderId': orderId,
      'productId': productId,
      'quantity': quantity,
      'price': price,
    };
  }

   @override
  String toString() {
    return 'OrderItem{id: $id, orderId: $orderId, productId: $productId, quantity: $quantity, price: $price}';
  }
}

class Product {
  final int? id;
  final String name;
  final double price;
  final int stock;

  Product({this.id, required this.name, required this.price, required this.stock});

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'price': price,
      'stock': stock,
    };
  }
  
  static Product fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'],
      name: map['name'],
      price: map['price'],
      stock: map['stock'],
    );
  }


   @override
  String toString() {
    return 'Product{id: $id, name: $name, price: $price, stock: $stock}';
  }
}



class OrdersDatabase {
  static final OrdersDatabase instance = OrdersDatabase._init();
  static Database? _database;

  OrdersDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('orders.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
    // Таблиця замовлень
    await db.execute('''
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL,
      totalAmount REAL NOT NULL,
      status TEXT NOT NULL,
      createdAt TEXT NOT NULL
    )
    ''');
    // Таблиця items замовлення
    await db.execute('''
    CREATE TABLE order_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      orderId INTEGER NOT NULL,
      productId INTEGER NOT NULL,
      quantity INTEGER NOT NULL,
      price REAL NOT NULL,
      FOREIGN KEY (orderId) REFERENCES orders (id) ON DELETE CASCADE,
      FOREIGN KEY (productId) REFERENCES products (id)
    )
    ''');
    // Таблиця продуктів
    await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      price REAL NOT NULL,
      stock INTEGER NOT NULL
    )
    ''');
    // Індекси
    await db.execute('CREATE INDEX idx_order_user ON orders (userId)');
    await db.execute('CREATE INDEX idx_item_order ON order_items (orderId)');
    await db.execute('CREATE INDEX idx_item_product ON order_items (productId)');
  }
   Future close() async {
    final db = await instance.database;
    db.close();
  }
}


class OrderItemRequest {
  final int productId;
  final int quantity;

  OrderItemRequest({required this.productId, required this.quantity});
}

class OrderService {
  final OrdersDatabase _dbHelper = OrdersDatabase.instance;

  Future<void> seedProducts() async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
        await txn.delete('products');
        await txn.insert('products', {'name': 'Laptop', 'price': 1200.0, 'stock': 10});
        await txn.insert('products', {'name': 'Mouse', 'price': 25.0, 'stock': 50});
        await txn.insert('products', {'name': 'Keyboard', 'price': 75.0, 'stock': 30});
    });
    developer.log('Seeded products');
  }

  Future<int?> createOrder(
    int userId,
    List<OrderItemRequest> items,
  ) async {
    final db = await _dbHelper.database;
    try {
      return await db.transaction((txn) async {
        for (var item in items) {
          final productResult = await txn.query(
            'products',
            where: 'id = ?',
            whereArgs: [item.productId],
          );
          if (productResult.isEmpty) {
            throw Exception('Product ${item.productId} not found');
          }
          final product = productResult.first;
          final stock = product['stock'] as int;
          if (stock < item.quantity) {
            throw Exception('Not enough stock for product ${item.productId}');
          }
        }
        double totalAmount = 0;
        for (var item in items) {
          final productResult = await txn.query(
            'products',
            columns: ['price'],
            where: 'id = ?',
            whereArgs: [item.productId],
          );
          final price = productResult.first['price'] as double;
          totalAmount += price * item.quantity;
        }
        final orderId = await txn.insert('orders', {
          'userId': userId,
          'totalAmount': totalAmount,
          'status': 'pending',
          'createdAt': DateTime.now().toIso8601String(),
        });
        var batch = txn.batch();
        for (var item in items) {
          final productResult = await txn.query(
            'products',
            columns: ['price'],
            where: 'id = ?',
            whereArgs: [item.productId],
          );
          final price = productResult.first['price'] as double;

          batch.insert('order_items', {
            'orderId': orderId,
            'productId': item.productId,
            'quantity': item.quantity,
            'price': price,
          });
          batch.rawUpdate(
            'UPDATE products SET stock = stock - ? WHERE id = ?',
            [item.quantity, item.productId],
          );
        }
        await batch.commit(noResult: true);
        
        developer.log('Order created: $orderId');
        return orderId;
      });
    } catch (e) {
      developer.log('Error creating order: $e');
      throw e;
    }
  }

  Future<bool> cancelOrder(int orderId) async {
    final db = await _dbHelper.database;
    try {
      return await db.transaction((txn) async {

        final items = await txn.query(
          'order_items',
          where: 'orderId = ?',
          whereArgs: [orderId],
        );


        var batch = txn.batch();
        for (var item in items) {
          batch.rawUpdate(
            'UPDATE products SET stock = stock + ? WHERE id = ?',
            [item['quantity'], item['productId']],
          );
        }
        await batch.commit(noResult: true);
        

        await txn.update(
          'orders',
          {'status': 'cancelled'},
          where: 'id = ?',
          whereArgs: [orderId],
        );
        return true;
      });
    } catch (e) {
      developer.log('Error cancelling order: $e');
      return false;
    }
  }
  
  Future<bool> completeFirstPendingOrder() async {
      final db = await _dbHelper.database;
      final pendingOrders = await db.query('orders', where: 'status = ?', whereArgs: ['pending'], limit: 1);
      if (pendingOrders.isNotEmpty) {
          final orderId = pendingOrders.first['id'] as int;
          await db.update('orders', {'status': 'completed'}, where: 'id = ?', whereArgs: [orderId]);
          return true;
      }
      return false;
  }

  Future<void> updateOrdersStatus(List<int> orderIds, String status) async {
    final db = await _dbHelper.database;
    Batch batch = db.batch();
    for (var orderId in orderIds) {
      batch.update(
        'orders',
        {'status': status},
        where: 'id = ?',
        whereArgs: [orderId],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteOldOrders(DateTime before) async {
    final db = await _dbHelper.database;
    await db.delete(
      'orders',
      where: 'createdAt < ? AND status = ?',
      whereArgs: [before.toIso8601String(), 'completed'],
    );
  }

  Future<Map<String, dynamic>?> getOrderDetails(int orderId) async {
    final db = await _dbHelper.database;
    final orderData = await db.rawQuery('''
      SELECT o.*, COUNT(oi.id) as itemsCount
      FROM orders o
      LEFT JOIN order_items oi ON o.id = oi.orderId
      WHERE o.id = ?
      GROUP BY o.id
    ''', [orderId]);
    if (orderData.isEmpty) return null;

    final items = await db.rawQuery('''
      SELECT oi.*, p.name as productName
      FROM order_items oi
      INNER JOIN products p ON oi.productId = p.id
      WHERE oi.orderId = ?
    ''', [orderId]);

    return {
      'order': orderData.first,
      'items': items,
    };
  }

  Future<List<Map<String, dynamic>>> getTopProducts(int limit) async {
    final db = await _dbHelper.database;
    return await db.rawQuery('''
      SELECT p.*, SUM(oi.quantity) as totalSold
      FROM products p
      INNER JOIN order_items oi ON p.id = oi.productId
      INNER JOIN orders o ON oi.orderId = o.id
      WHERE o.status = 'completed'
      GROUP BY p.id
      ORDER BY totalSold DESC
      LIMIT ?
    ''', [limit]);
  }

  Future<Map<String, dynamic>> getSalesStats() async {
    final db = await _dbHelper.database;
    final totalRevenue = await db.rawQuery('''
      SELECT SUM(totalAmount) as revenue
      FROM orders
      WHERE status = 'completed'
    ''');
    final ordersCount = await db.rawQuery('''
      SELECT
        COUNT(*) as total,
        SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) as pending,
        SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
        SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) as cancelled
      FROM orders
    ''');
    return {
      'revenue': totalRevenue.first['revenue'] ?? 0.0,
      'orders': ordersCount.first,
    };
  }

  Future<List<Map<String, dynamic>>> getAllOrders() async {
      final db = await _dbHelper.database;
      return await db.query('orders', orderBy: 'createdAt DESC');
  }

    Future<List<Product>> getAllProducts() async {
      final db = await _dbHelper.database;
      final maps = await db.query('products');
      return maps.map((map) => Product.fromMap(map)).toList();
  }
}




void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Order System Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 16)),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            textStyle: const TextStyle(fontSize: 12),
          )
        )
      ),
      home: const OrderScreen(),
    );
  }
}

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key});

  @override
  _OrderScreenState createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final OrderService _orderService = OrderService();
  String _output = 'Press "1. Seed Products" to begin.';


  Future<void> _runAction(Function action, {String? successMessage}) async {
    setState(() { _output = 'Loading...'; });
    try {
      final result = await action();
      setState(() {
        if (successMessage != null) {
          _output = successMessage;
        } else {

          if (result is Map || result is List) {
             _output = '--- RESULT ---\n${result.toString().replaceAll('},', '},\n')}';
          } else {
             _output = result.toString();
          }
        }
      });
    } catch (e) {
      setState(() {
        _output = '--- ACTION FAILED ---\n${e.toString()}';
      });
    }
  }



  Future<void> _seedProducts() async {
    await _runAction(_orderService.seedProducts, successMessage: '✅ Products seeded successfully.');
  }

  Future<void> _getProducts() async {
    await _runAction(_orderService.getAllProducts);
  }

  Future<void> _createGoodOrder() async {
    setState(() { _output = 'Loading...'; });
    try {
      final products = await _orderService.getAllProducts();
      if (products.length < 2) {
        setState(() { _output = '❌ Not enough products in DB. Seed products first.'; });
        return;
      }
      final orderId = await _orderService.createOrder(1, [
        OrderItemRequest(productId: products[0].id!, quantity: 1),
        OrderItemRequest(productId: products[1].id!, quantity: 2),
      ]);
      setState(() { _output = '✅ Successfully created Order ID: $orderId'; });

    } catch (e) {
       setState(() { _output = '--- ACTION FAILED ---\n${e.toString()}'; });
    }
  }
  
  Future<void> _createFaultyOrder() async {
     setState(() { _output = 'Loading...'; });
     try {
      final products = await _orderService.getAllProducts();
       if (products.isEmpty) {
        setState(() { _output = '❌ No products in DB. Seed products first.'; });
        return;
      }
      await _orderService.createOrder(2, [
        OrderItemRequest(productId: products[0].id!, quantity: 999),
      ]);
      setState(() { _output = '❌ Faulty order was created, which is an error.'; });
     } catch(e) {
        setState(() { _output = '✅ Order creation failed as expected (Not enough stock). Transaction rolled back.'; });
     }
  }

  Future<void> _getOrders() async {
    await _runAction(_orderService.getAllOrders);
  }
  
  Future<void> _completeOrderAndShowTop() async {
    setState(() { _output = 'Loading...'; });
    final completed = await _orderService.completeFirstPendingOrder();
    if (completed) {
       final result = await _orderService.getTopProducts(3);
       setState(() {
          _output = '✅ Order completed. Top products report:\n${result.toString().replaceAll('},', '},\n')}';
       });

    } else {
      setState(() { _output = 'ℹ️ No pending orders to complete.'; });
    }
  }

  Future<void> _getSalesStats() async {
    await _runAction(_orderService.getSalesStats);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order System Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8.0,
              runSpacing: 4.0,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton(onPressed: _seedProducts, child: const Text('1. Seed Products')),
                ElevatedButton(onPressed: _createGoodOrder, child: const Text('2. Create Good Order')),
                ElevatedButton(onPressed: _completeOrderAndShowTop, child: const Text('3. Complete Order & Report')),
                ElevatedButton(onPressed: _getProducts, child: const Text('View Products')),
                ElevatedButton(onPressed: _getOrders, child: const Text('View All Orders')),
                ElevatedButton(onPressed: _getSalesStats, child: const Text('Sales Stats')),
                 ElevatedButton(
                  onPressed: _createFaultyOrder,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
                  child: const Text('Test Rollback'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Output:', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8.0),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(_output, style: Theme.of(context).textTheme.bodyMedium),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}