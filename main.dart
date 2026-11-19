import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const premiumNavy = Color(0xFF0C1729);
const premiumGold = Color(0xFFE3BB6A);

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
final db = Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Set SUPABASE_URL and SUPABASE_ANON_KEY using --dart-define')))));
    return;
  }
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const CarwashApp());
}

class CarwashApp extends StatelessWidget {
  const CarwashApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'التقنية المصرية', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: premiumNavy), scaffoldBackgroundColor: const Color(0xFFF4F6FA), appBarTheme: const AppBarTheme(backgroundColor: premiumNavy, foregroundColor: Colors.white, centerTitle: false), tabBarTheme: const TabBarThemeData(labelColor: premiumGold, unselectedLabelColor: Colors.white70, indicatorColor: premiumGold), cardTheme: CardThemeData(color: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))))),
    locale: const Locale('ar'),
    builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
    home: const AuthGate(),
  );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}
class _AuthGateState extends State<AuthGate> {
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: db.auth.onAuthStateChange,
    builder: (context, snap) => db.auth.currentUser == null ? const LoginPage() : const HomePage(),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}
class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String? error;
  Future<void> login() async {
    setState(() {busy = true; error = null;});
    try { await db.auth.signInWithPassword(email: email.text.trim(), password: password.text); }
    catch (e) { if (mounted) setState(() => error = 'تعذر تسجيل الدخول: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  void dispose() { email.dispose(); password.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('التقنية المصرية')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Padding(
      padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.local_car_wash, size: 72), const SizedBox(height: 20),
        TextField(controller: email, decoration: const InputDecoration(labelText: 'البريد الإلكتروني')),
        TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 20), FilledButton(onPressed: busy ? null : login, child: Text(busy ? 'جاري الدخول...' : 'تسجيل الدخول')),
      ]),
    ))),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  String role = 'customer';
  bool loading = true;
  @override
  void initState() { super.initState(); loadRole(); }
  Future<void> loadRole() async {
    try {
      final row = await db.from('profiles').select('role').eq('id', db.auth.currentUser!.id).single();
      if (mounted) setState(() => role = row['role'] as String);
    } catch (_) { /* No profile yet: restrict to customer UI. */ }
    if (mounted) setState(() => loading = false);
  }
  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final staff = role == 'admin' || role == 'employee';
    return DefaultTabController(length: staff ? (role == 'admin' ? 3 : 2) : 1,
      child: Scaffold(appBar: AppBar(title: Text('التقنية المصرية — ${role == 'admin' ? 'الإدارة' : role == 'employee' ? 'الموظف' : 'العميل'}'),
        actions: [IconButton(onPressed: () => db.auth.signOut(), icon: const Icon(Icons.logout))],
        bottom: TabBar(tabs: [if (staff) const Tab(text: 'طلب جديد'), const Tab(text: 'الطلبات'), if (role == 'admin') const Tab(text: 'التقارير')]),
        body: TabBarView(children: [if (staff) const NewOrderPage(), const OrdersPage(), if (role == 'admin') const ReportsPage()])),
    );
  }
}

class NewOrderPage extends StatefulWidget {
  const NewOrderPage({super.key});
  @override
  State<NewOrderPage> createState() => _NewOrderPageState();
}
class _NewOrderPageState extends State<NewOrderPage> {
  final plate = TextEditingController(), customerName = TextEditingController(),
      phone = TextEditingController(), discount = TextEditingController(text: '0'),
      initialPayment = TextEditingController(text: '0');
  List<Map<String, dynamic>> services = [];
  final Map<String, int> quantities = {};
  String payment = 'unpaid', invoiceKind = 'simplified';
  bool busy = false;
  @override
  void initState() { super.initState(); loadServices(); }
  Future<void> loadServices() async {
    try {
      final rows = await db.from('services').select('id,name,price_sar').eq('active', true).order('name');
      if (mounted) setState(() => services = List<Map<String, dynamic>>.from(rows));
    } catch (e) { if (mounted) message('تعذر تحميل الخدمات: $e'); }
  }
  double get subtotal => services.fold(0.0, (sum, s) => sum +
    ((num.tryParse('${s['price_sar']}')?.toDouble() ?? 0) * (quantities[s['id']] ?? 0)));
  double get reduction => double.tryParse(discount.text) ?? 0;
  double get total => (subtotal - reduction).clamp(0, double.infinity).toDouble();
  void message(String value) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value))); }
  Future<void> save() async {
    final amount = double.tryParse(initialPayment.text);
    if (plate.text.trim().length < 2 || quantities.values.every((q) => q == 0)) {
      message('أدخل اللوحة واختر خدمة واحدة على الأقل'); return;
    }
    if (reduction < 0 || reduction > subtotal || amount == null || amount < 0 || amount > total) {
      message('راجع الخصم والمبلغ المدفوع'); return;
    }
    if ((amount == 0 && payment != 'unpaid') || (amount > 0 && payment == 'unpaid')) {
      message('اختر طريقة دفع تتوافق مع المبلغ المدفوع'); return;
    }
    setState(() => busy = true);
    try {
      await db.rpc('create_wash_order_v2', params: {
        'p_plate': plate.text.trim(), 'p_customer_name': customerName.text.trim(),
        'p_customer_phone': phone.text.trim(),
        'p_items': quantities.entries.where((e) => e.value > 0).map((e) =>
          {'service_id': e.key, 'quantity': e.value}).toList(),
        'p_discount_sar': reduction, 'p_initial_payment_sar': amount,
        'p_payment_method': payment, 'p_invoice_kind': invoiceKind,
      });
      if (mounted) { message('تم حفظ الطلب ومسودة الفاتورة');
        plate.clear(); customerName.clear(); phone.clear(); discount.text='0';
        initialPayment.text='0'; setState(() => quantities.clear()); }
    } catch (e) { if (mounted) message('تعذر الحفظ: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  void dispose() {
    for (final c in [plate,customerName,phone,discount,initialPayment]) { c.dispose(); }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(18), children: [
    const Text('نقطة البيع — طلب جديد', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    TextField(controller: plate, decoration: const InputDecoration(labelText: 'رقم اللوحة *')),
    TextField(controller: customerName, decoration: const InputDecoration(labelText: 'اسم العميل')),
    TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الجوال')),
    const SizedBox(height: 14), const Text('الخدمات والكميات', style: TextStyle(fontWeight: FontWeight.bold)),
    for (final s in services) Card(child: ListTile(
      title: Text('${s['name']}'), subtitle: Text('${s['price_sar']} ر.س'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() {
          final id=s['id'] as String; quantities[id]=((quantities[id]??0)-1).clamp(0,20);
        })),
        Text('${quantities[s['id']]??0}'),
        IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => setState(() {
          final id=s['id'] as String; quantities[id]=((quantities[id]??0)+1).clamp(0,20);
        })),
      ]),
    )),
    TextField(controller: discount, keyboardType: const TextInputType.numberWithOptions(decimal:true),
      decoration: const InputDecoration(labelText: 'خصم بالريال (صلاحيات الخصم تُضاف لاحقًا)'), onChanged: (_) => setState(() {})),
    TextField(controller: initialPayment, keyboardType: const TextInputType.numberWithOptions(decimal:true),
      decoration: const InputDecoration(labelText: 'المبلغ المستلم الآن'), onChanged: (_) => setState(() {})),
    DropdownButtonFormField<String>(initialValue: payment, decoration: const InputDecoration(labelText: 'طريقة السداد'),
      items: const [DropdownMenuItem(value:'unpaid',child:Text('بدون سداد')),
        DropdownMenuItem(value:'cash',child:Text('نقدًا')),DropdownMenuItem(value:'card',child:Text('شبكة'))],
      onChanged: (v) => setState(() => payment=v!)),
    DropdownButtonFormField<String>(initialValue: invoiceKind, decoration: const InputDecoration(labelText: 'نوع مسودة الفاتورة'),
      items: const [DropdownMenuItem(value:'simplified',child:Text('مبسطة — أفراد')),
        DropdownMenuItem(value:'standard',child:Text('ضريبية — شركات'))],
      onChanged: (v) => setState(() => invoiceKind=v!)),
    const SizedBox(height: 12),
    Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
      Text('قبل الخصم: ${subtotal.toStringAsFixed(2)} ر.س'),
      Text('الإجمالي شامل الضريبة: ${total.toStringAsFixed(2)} ر.س', style: const TextStyle(fontWeight:FontWeight.bold)),
      Text('ضريبة مضمّنة (تقديرية): ${(total*15/115).toStringAsFixed(2)} ر.س'),
      Text('المتبقي: ${(total-(double.tryParse(initialPayment.text)??0)).toStringAsFixed(2)} ر.س'),
    ]))),
    FilledButton(onPressed: busy ? null : save, child: Text(busy?'جاري الحفظ...':'حفظ الطلب ومسودة الفاتورة')),
    const Text('مسودة داخلية فقط؛ لا تصدر فاتورة ZATCA رسمية.', style: TextStyle(color:Colors.deepOrange)),
  ]);
}

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}
class _OrdersPageState extends State<OrdersPage> {
  Future<List<Map<String, dynamic>>> load() async => List<Map<String, dynamic>>.from(
    await db.from('orders').select('id,created_at,plate,customer_name,service_name,total_sar,payment_status').order('created_at', ascending: false).limit(100));
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(future: load(), builder: (context, snap) {
    if (!snap.hasData) return Center(child: Text(snap.hasError ? 'تعذر تحميل الطلبات: ${snap.error}' : 'جاري التحميل...'));
    return RefreshIndicator(onRefresh: () async { setState(() {}); }, child: ListView(children: [
      for (final o in snap.data!) ListTile(
        title: Text('${o['service_name']} — ${o['total_sar']} ر.س'),
        subtitle: Text('${o['plate']} • ${o['customer_name'] ?? ''} • ${o['created_at'].toString().substring(0, 10)}'),
        trailing: Text(o['payment_status'] == 'paid' ? 'مدفوع' : 'غير مدفوع'),
      ),
      if (snap.data!.isEmpty) const ListTile(title: Text('لا توجد طلبات بعد')),
    ]));
  });
}

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: db.rpc('daily_sales_summary').then((value) => List<Map<String, dynamic>>.from(value as List)),
    builder: (context, snap) {
      if (!snap.hasData) return Center(child: Text(snap.hasError ? 'خطأ: ${snap.error}' : 'جاري التحميل...'));
      return ListView(padding: const EdgeInsets.all(20), children: [
        const Text('تقرير المبيعات اليومية', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        for (final row in snap.data!) Card(child: ListTile(title: Text('${row['day']}'),
          subtitle: Text('عدد الطلبات: ${row['orders_count']}'),
          trailing: Text('${row['paid_total_sar']} ر.س'))),
      ]);
    },
  );
}
