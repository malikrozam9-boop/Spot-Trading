// Spot Signal - single file Flutter app (Android)
// Tabs: Coins | Heatmap | Nodes (on-chain) | Chart (TradingView) | AI Signal
// Data: Binance + Bybit public APIs, CoinMarketCap (optional key), CoinMetrics community, alternative.me, Gemini (optional key)

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

const kBg = Color(0xFF0B0E11);
const kCard = Color(0xFF161A1E);
const kGreen = Color(0xFF0ECB81);
const kRed = Color(0xFFF6465D);
const kYellow = Color(0xFFF0B90B);

final ValueNotifier<String> selected = ValueNotifier<String>('BTC');
final ValueNotifier<int> tabIndex = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.load();
  runApp(const SpotSignalApp());
}

// ---------------------------------------------------------------- settings

class Settings {
  static String cmcKey = '';
  static String geminiKey = '';
  static String geminiModel = 'gemini-flash-latest';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    cmcKey = p.getString('cmc') ?? '';
    geminiKey = p.getString('gem') ?? '';
    geminiModel = p.getString('model') ?? 'gemini-flash-latest';
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('cmc', cmcKey);
    await p.setString('gem', geminiKey);
    await p.setString('model', geminiModel);
  }
}

// ---------------------------------------------------------------- helpers

String fp(double p) {
  if (p >= 1000) return p.toStringAsFixed(1);
  if (p >= 1) return p.toStringAsFixed(3);
  return p.toStringAsFixed(6);
}

String fb(double v) {
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
  if (a >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
  return v.toStringAsFixed(0);
}

Future<dynamic> getJson(String url, {Map<String, String>? headers}) async {
  final r = await http
      .get(Uri.parse(url), headers: headers)
      .timeout(const Duration(seconds: 20));
  if (r.statusCode != 200) {
    throw Exception('HTTP ${r.statusCode} (${Uri.parse(url).host})');
  }
  return jsonDecode(r.body);
}

Widget card(Widget child) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );

Widget kv(String k, String v, {Color? c}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: Colors.white60)),
          Text(v, style: TextStyle(color: c ?? Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );

// ---------------------------------------------------------------- models

class Candle {
  final int t;
  final double o, h, l, c, v;
  Candle(this.t, this.o, this.h, this.l, this.c, this.v);
}

class Coin {
  final String symbol;
  final double price, change, volume;
  double? mcap;
  Coin(this.symbol, this.price, this.change, this.volume);
}

class Deriv {
  List<List<double>> hist = []; // [timestamp, open interest USD] (Binance)
  double? funding; // Binance
  double? bybitFunding;
  double? bybitOiUsd;
  double? ls; // Binance global long/short account ratio
}

// ---------------------------------------------------------------- market data

class Market {
  static const stable = {
    'USDC', 'FDUSD', 'TUSD', 'USDP', 'DAI', 'EUR', 'AEUR', 'USDE', 'XUSD', 'BUSD', 'PAXG'
  };

  static Future<List<Coin>> coins() async {
    final list = <Coin>[];
    try {
      final d = await getJson('https://api.binance.com/api/v3/ticker/24hr') as List;
      for (final e in d) {
        final s = e['symbol'] as String;
        if (!s.endsWith('USDT')) continue;
        final base = s.substring(0, s.length - 4);
        if (stable.contains(base)) continue;
        list.add(Coin(base, double.parse(e['lastPrice']),
            double.parse(e['priceChangePercent']), double.parse(e['quoteVolume'])));
      }
    } catch (_) {
      final d = await getJson('https://api.bybit.com/v5/market/tickers?category=spot');
      for (final e in d['result']['list']) {
        final s = e['symbol'] as String;
        if (!s.endsWith('USDT')) continue;
        final base = s.substring(0, s.length - 4);
        if (stable.contains(base)) continue;
        list.add(Coin(base, double.parse(e['lastPrice']),
            double.parse(e['price24hPcnt']) * 100, double.parse(e['turnover24h'])));
      }
    }
    list.sort((a, b) => b.volume.compareTo(a.volume));
    final top = list.take(80).toList();
    if (Settings.cmcKey.isNotEmpty) {
      try {
        final d = await getJson(
            'https://pro-api.coinmarketcap.com/v1/cryptocurrency/listings/latest?limit=500',
            headers: {'X-CMC_PRO_API_KEY': Settings.cmcKey});
        final m = <String, double>{};
        for (final e in d['data']) {
          final mc = e['quote']['USD']['market_cap'];
          if (mc != null) m[e['symbol']] = (mc as num).toDouble();
        }
        for (final c in top) {
          c.mcap = m[c.symbol];
        }
      } catch (_) {}
    }
    return top;
  }

  static Future<List<Candle>> candles(String base, String iv, {int limit = 200}) async {
    final sym = '${base}USDT';
    for (final host in [
      'https://fapi.binance.com/fapi/v1/klines',
      'https://api.binance.com/api/v3/klines'
    ]) {
      try {
        final d = await getJson('$host?symbol=$sym&interval=$iv&limit=$limit') as List;
        return d
            .map<Candle>((k) => Candle((k[0] as num).toInt(), double.parse(k[1]),
                double.parse(k[2]), double.parse(k[3]), double.parse(k[4]), double.parse(k[5])))
            .toList();
      } catch (_) {}
    }
    final bi = {'15m': '15', '1h': '60', '4h': '240'}[iv] ?? '60';
    final d = await getJson(
        'https://api.bybit.com/v5/market/kline?category=linear&symbol=$sym&interval=$bi&limit=$limit');
    return (d['result']['list'] as List)
        .reversed
        .map<Candle>((k) => Candle(int.parse(k[0]), double.parse(k[1]), double.parse(k[2]),
            double.parse(k[3]), double.parse(k[4]), double.parse(k[5])))
        .toList();
  }

  static Future<Deriv> deriv(String base, String iv) async {
    final sym = '${base}USDT';
    final d = Deriv();
    try {
      final h = await getJson(
          'https://fapi.binance.com/futures/data/openInterestHist?symbol=$sym&period=$iv&limit=200') as List;
      d.hist = h
          .map<List<double>>((e) => [
                (e['timestamp'] as num).toDouble(),
                double.parse(e['sumOpenInterestValue'].toString())
              ])
          .toList();
    } catch (_) {}
    try {
      final p = await getJson('https://fapi.binance.com/fapi/v1/premiumIndex?symbol=$sym');
      d.funding = double.parse(p['lastFundingRate'].toString());
    } catch (_) {}
    try {
      final l = await getJson(
          'https://fapi.binance.com/futures/data/globalLongShortAccountRatio?symbol=$sym&period=$iv&limit=1') as List;
      if (l.isNotEmpty) d.ls = double.parse(l[0]['longShortRatio'].toString());
    } catch (_) {}
    try {
      final b = await getJson(
          'https://api.bybit.com/v5/market/tickers?category=linear&symbol=$sym');
      final it = b['result']['list'][0];
      d.bybitFunding = double.tryParse(it['fundingRate'].toString());
      final oi = double.tryParse(it['openInterest'].toString());
      final px = double.tryParse(it['lastPrice'].toString());
      if (oi != null && px != null) d.bybitOiUsd = oi * px;
    } catch (_) {}
    return d;
  }

  static Future<int?> fng() async {
    try {
      final d = await getJson('https://api.alternative.me/fng/?limit=1');
      return int.parse(d['data'][0]['value'].toString());
    } catch (_) {
      return null;
    }
  }

  static Future<OnChain> onchain(String asset) async {
    final m = <String, List<double>>{};
    for (final k in ['CapMVRVCur', 'AdrActCnt', 'TxCnt', 'NVTAdj']) {
      try {
        final d = await getJson(
            'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics?assets=$asset&metrics=$k&frequency=1d&page_size=40&paging_from=end');
        final vals = (d['data'] as List)
            .map<double?>((e) => double.tryParse('${e[k]}'))
            .whereType<double>()
            .toList();
        if (vals.isNotEmpty) m[k] = vals;
      } catch (_) {}
    }
    return OnChain(m);
  }

  static Future<String> gemini(String prompt) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/${Settings.geminiModel}:generateContent';
    final r = await http
        .post(Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': Settings.geminiKey,
            },
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ]
            }))
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception('Gemini ${r.statusCode}: ${r.body.substring(0, math.min(200, r.body.length))}');
    }
    final j = jsonDecode(r.body);
    return j['candidates'][0]['content']['parts'][0]['text'] as String;
  }
}

class OnChain {
  final Map<String, List<double>> m;
  double score = 0;
  final List<String> notes = [];

  OnChain(this.m) {
    final mv = last('CapMVRVCur');
    if (mv != null) {
      if (mv < 1) {
        score += 2;
        notes.add('MVRV ${mv.toStringAsFixed(2)}: undervalued zone (bullish)');
      } else if (mv < 2.5) {
        score += 0.5;
        notes.add('MVRV ${mv.toStringAsFixed(2)}: healthy zone');
      } else if (mv > 3.5) {
        score -= 2;
        notes.add('MVRV ${mv.toStringAsFixed(2)}: overheated (bearish)');
      } else {
        notes.add('MVRV ${mv.toStringAsFixed(2)}: warm zone');
      }
    }
    final a7 = avg('AdrActCnt', 7);
    final a30 = avg('AdrActCnt', 30);
    if (a7 != null && a30 != null) {
      if (a7 > a30 * 1.05) {
        score += 1;
        notes.add('Active addresses badh rahe hain (bullish)');
      } else if (a7 < a30 * 0.95) {
        score -= 1;
        notes.add('Active addresses ghat rahe hain (bearish)');
      }
    }
    score = score.clamp(-2.0, 2.0).toDouble();
  }

  double? last(String k) => (m[k] != null && m[k]!.isNotEmpty) ? m[k]!.last : null;

  double? avg(String k, int n) {
    final v = m[k];
    if (v == null || v.length < n) return null;
    final s = v.sublist(v.length - n);
    return s.reduce((a, b) => a + b) / s.length;
  }
}

// ---------------------------------------------------------------- indicators

List<double> ema(List<double> x, int p) {
  final k = 2 / (p + 1);
  final out = <double>[];
  double e = x.first;
  for (final v in x) {
    e = out.isEmpty ? v : v * k + e * (1 - k);
    out.add(e);
  }
  return out;
}

double rsi(List<double> c, [int p = 14]) {
  if (c.length <= p) return 50;
  double g = 0, l = 0;
  for (int i = 1; i <= p; i++) {
    final d = c[i] - c[i - 1];
    if (d >= 0) {
      g += d;
    } else {
      l -= d;
    }
  }
  g /= p;
  l /= p;
  for (int i = p + 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    g = (g * (p - 1) + (d > 0 ? d : 0)) / p;
    l = (l * (p - 1) + (d < 0 ? -d : 0)) / p;
  }
  if (l == 0) return 100;
  return 100 - 100 / (1 + g / l);
}

double atr(List<Candle> c, [int p = 14]) {
  final trs = <double>[];
  for (int i = 1; i < c.length; i++) {
    trs.add(math.max(c[i].h - c[i].l,
        math.max((c[i].h - c[i - 1].c).abs(), (c[i].l - c[i - 1].c).abs())));
  }
  final s = trs.length > p ? trs.sublist(trs.length - p) : trs;
  return s.reduce((a, b) => a + b) / s.length;
}

// ---------------------------------------------------------------- liquidation heatmap engine
// Estimated (not exact): new open interest is spread over leverage tiers (10x/25x/50x/100x),
// each position gets a liquidation price, and is removed once price trades through it.

class Cluster {
  final int bin, start;
  int end;
  final double w;
  final bool isLong;
  bool alive;
  Cluster(this.bin, this.start, this.end, this.w, this.isLong, this.alive);
}

class Level {
  final double price, w;
  final bool isLong;
  Level(this.price, this.w, this.isLong);
}

class HeatResult {
  final List<Candle> candles;
  final double lo, hi;
  final int bins;
  final List<Cluster> clusters;
  HeatResult(this.candles, this.lo, this.hi, this.bins, this.clusters);
  double get step => (hi - lo) / bins;
}

HeatResult buildHeat(List<Candle> cs, List<List<double>> hist, String interval) {
  const bins = 90;
  double lo = cs.map((c) => c.l).reduce(math.min);
  double hi = cs.map((c) => c.h).reduce(math.max);
  final pad = (hi - lo) * 0.2;
  final rawLo = lo;
  lo = lo - pad;
  if (lo <= 0) lo = rawLo * 0.5;
  hi = hi + pad;
  final step = (hi - lo) / bins;
  final pm = {'15m': 900000.0, '1h': 3600000.0, '4h': 14400000.0}[interval] ?? 3600000.0;
  final n = cs.length;
  final oi = List<double>.filled(n, double.nan);
  for (final h in hist) {
    final idx = ((h[0] - cs.first.t) / pm).floor();
    if (idx >= 0 && idx < n) oi[idx] = h[1];
  }
  const tiers = [10.0, 25.0, 50.0, 100.0];
  const wts = [0.35, 0.30, 0.20, 0.15];
  const mm = 0.005;
  final clusters = <Cluster>[];
  for (int i = 1; i < n; i++) {
    if (oi[i].isNaN || oi[i - 1].isNaN) continue;
    final d = oi[i] - oi[i - 1];
    if (d <= 0) continue;
    final entry = (cs[i].h + cs[i].l + cs[i].c) / 3;
    final longShare = cs[i].c >= cs[i].o ? 0.6 : 0.4;
    for (int k = 0; k < tiers.length; k++) {
      final lev = tiers[k];
      for (final isLong in [true, false]) {
        final liq = isLong ? entry * (1 - 1 / lev + mm) : entry * (1 + 1 / lev - mm);
        if (liq <= lo || liq >= hi) continue;
        final w = d * wts[k] * (isLong ? longShare : 1 - longShare);
        int end = n - 1;
        bool alive = true;
        for (int j = i + 1; j < n; j++) {
          final hit = isLong ? cs[j].l <= liq : cs[j].h >= liq;
          if (hit) {
            end = j;
            alive = false;
            break;
          }
        }
        int bin = ((liq - lo) / step).floor();
        bin = math.max(0, math.min(bins - 1, bin));
        clusters.add(Cluster(bin, i, end, w, isLong, alive));
      }
    }
  }
  return HeatResult(cs, lo, hi, bins, clusters);
}

List<Level> aliveLevels(HeatResult r) {
  final m = <String, double>{};
  for (final c in r.clusters) {
    if (!c.alive) continue;
    final key = '${c.isLong ? 1 : 0}_${c.bin}';
    m[key] = (m[key] ?? 0) + c.w;
  }
  final out = <Level>[];
  m.forEach((key, w) {
    final parts = key.split('_');
    final isLong = parts[0] == '1';
    final bin = int.parse(parts[1]);
    out.add(Level(r.lo + (bin + 0.5) * r.step, w, isLong));
  });
  return out;
}

Color heatColor(double t) {
  const purple = Color(0xFF3B1C6E);
  const teal = Color(0xFF1ABC9C);
  const yellow = Color(0xFFFFE600);
  final c = t < 0.5
      ? Color.lerp(purple, teal, t * 2)!
      : Color.lerp(teal, yellow, (t - 0.5) * 2)!;
  return c.withAlpha(math.max(0, math.min(255, (90 + 165 * t).round())));
}

class HeatPainter extends CustomPainter {
  final HeatResult r;
  HeatPainter(this.r);

  void _text(Canvas c, String s, Offset o, {Color col = Colors.white70, double fs = 10}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: col, fontSize: fs)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0F1216));
    final n = r.candles.length;
    final cw = size.width / n;
    final bh = size.height / r.bins;
    double maxW = 0;
    for (final c in r.clusters) {
      if (c.w > maxW) maxW = c.w;
    }
    if (maxW > 0) {
      for (final c in r.clusters) {
        final t = math.sqrt(c.w / maxW).clamp(0.0, 1.0).toDouble();
        final rect = Rect.fromLTRB(
          c.start * cw,
          size.height - (c.bin + 1) * bh,
          (c.end + 1) * cw,
          size.height - c.bin * bh,
        );
        canvas.drawRect(rect, Paint()..color = heatColor(t));
      }
    }
    double y(double p) => size.height * (1 - (p - r.lo) / (r.hi - r.lo));
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (int i = 0; i < n; i++) {
      final x = (i + 0.5) * cw;
      final yy = y(r.candles[i].c);
      if (i == 0) {
        path.moveTo(x, yy);
      } else {
        path.lineTo(x, yy);
      }
    }
    canvas.drawPath(path, line);
    for (int i = 0; i <= 4; i++) {
      final p = r.lo + (r.hi - r.lo) * i / 4;
      _text(canvas, fp(p), Offset(4, (y(p) - 12).clamp(0.0, size.height - 12).toDouble()));
    }
    final last = r.candles.last.c;
    canvas.drawLine(Offset(0, y(last)), Offset(size.width, y(last)),
        Paint()..color = kYellow..strokeWidth = 0.8);
    _text(canvas, fp(last), Offset(size.width - 60, y(last) - 12), col: kYellow);
  }

  @override
  bool shouldRepaint(covariant HeatPainter old) => true;
}

// ---------------------------------------------------------------- signal engine (spot, long only)

class Plan {
  String symbol = '';
  String action = 'WAIT';
  double score = 50;
  double price = 0, atrV = 0;
  double? entry, sl, tp1, tp2, tp3, rr;
  List<String> pros = [];
  List<String> cons = [];

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'price': price,
        'action': action,
        'score': score.round(),
        'entry': entry,
        'stop_loss': sl,
        'tp1': tp1,
        'tp2': tp2,
        'tp3': tp3,
        'risk_reward_tp2': rr,
        'atr_1h': atrV,
        'bullish_factors': pros,
        'bearish_factors': cons,
      };
}

Future<Plan> analyze(String base, void Function(String) stage) async {
  stage('Candles le raha hoon...');
  final f1 = Market.candles(base, '1h');
  final f4 = Market.candles(base, '4h');
  final fBtc = base == 'BTC' ? f4 : Market.candles('BTC', '4h');
  final fDv = Market.deriv(base, '1h');
  final fFng = Market.fng();
  final c1 = await f1;
  final c4 = await f4;
  final btc = await fBtc;
  stage('Derivatives + sentiment...');
  final dv = await fDv;
  final fg = await fFng;
  OnChain? oc;
  if (base == 'BTC' || base == 'ETH') {
    stage('On-chain data...');
    oc = await Market.onchain(base.toLowerCase());
  }
  stage('Liquidity map bana raha hoon...');
  final heat = buildHeat(c1, dv.hist, '1h');
  final levels = aliveLevels(heat);

  final p = Plan()..symbol = base;
  final last = c1.last.c;
  final a = atr(c1);
  p.price = last;
  p.atrV = a;

  double s = 50;
  void add(double d, String msg) {
    s += d;
    if (d >= 0) {
      p.pros.add(msg);
    } else {
      p.cons.add(msg);
    }
  }

  final cl4 = c4.map((c) => c.c).toList();
  final e50 = ema(cl4, 50).last;
  final e200 = ema(cl4, 200).last;
  final l4 = cl4.last;
  final up4 = l4 > e50 && e50 > e200;
  final down4 = l4 < e50 && e50 < e200;
  if (up4) add(10, '4H uptrend (price > EMA50 > EMA200)');
  if (down4) add(-12, '4H downtrend (price < EMA50 < EMA200)');

  final cl1 = c1.map((c) => c.c).toList();
  if (last > ema(cl1, 50).last) {
    add(5, '1H price EMA50 ke upar');
  } else {
    add(-5, '1H price EMA50 ke neeche');
  }

  bool btcBear = false;
  if (base != 'BTC') {
    final bc = btc.map((c) => c.c).toList();
    if (bc.last > ema(bc, 50).last) {
      add(6, 'BTC 4H trend positive');
    } else {
      btcBear = true;
      add(-8, 'BTC 4H trend weak (alt buy risky)');
    }
  }

  final r = rsi(cl1);
  if (r < 30) {
    add(6, 'RSI ${r.toStringAsFixed(0)} oversold bounce zone');
  } else if (r <= 65) {
    add(3, 'RSI ${r.toStringAsFixed(0)} healthy');
  } else if (r > 75) {
    add(-8, 'RSI ${r.toStringAsFixed(0)} overbought');
  }

  final f = dv.funding;
  if (f != null) {
    if (f > 0.0005) {
      add(-6, 'Funding ${(f * 100).toStringAsFixed(3)}% high: longs crowded');
    } else if (f < -0.0001) {
      add(5, 'Funding negative: short squeeze fuel');
    }
  }
  if (dv.ls != null) {
    if (dv.ls! > 2.0) {
      add(-5, 'Long/Short ratio ${dv.ls!.toStringAsFixed(2)}: too many longs');
    } else if (dv.ls! < 0.9) {
      add(4, 'Long/Short ratio ${dv.ls!.toStringAsFixed(2)}: shorts crowded');
    }
  }

  if (dv.hist.length > 25 && c1.length > 25) {
    final oiChg = dv.hist.last[1] / dv.hist[dv.hist.length - 25][1] - 1;
    final pxChg = last / c1[c1.length - 25].c - 1;
    if (oiChg > 0.02 && pxChg > 0.01) {
      add(5, 'Price + Open Interest dono badh rahe (trend confirm)');
    } else if (oiChg > 0.02 && pxChg < -0.01) {
      add(-6, 'Price gir raha, OI barh raha (shorts attack)');
    } else if (oiChg < -0.03 && pxChg < -0.01) {
      add(2, 'OI ghat raha: longs flush ho chuke');
    }
  }

  // liquidity levels
  final longs = levels.where((l) => l.isLong && l.price < last).toList();
  final shorts = levels.where((l) => !l.isLong && l.price > last).toList();
  double maxW = 0;
  for (final l in levels) {
    if (l.w > maxW) maxW = l.w;
  }
  final strongLongs = longs.where((l) => l.w >= maxW * 0.25 && last - l.price <= 5 * a).toList()
    ..sort((x, y) => y.w.compareTo(x.w));
  final strongShorts = shorts.where((l) => l.w >= maxW * 0.25).toList()
    ..sort((x, y) => x.price.compareTo(y.price));

  final swingLow = c1.sublist(math.max(0, c1.length - 20)).map((c) => c.l).reduce(math.min);
  double support = swingLow;
  if (strongLongs.isNotEmpty) {
    support = strongLongs.first.price;
    add(6, 'Neeche strong liquidity zone ${fp(support)} (support)');
  } else if (dv.hist.isEmpty) {
    p.cons.add('Futures OI data nahi mila: heatmap signal use nahi hua');
  }
  if (strongShorts.isNotEmpty && strongShorts.first.price - last <= 8 * a) {
    add(4, 'Upar short-liquidation magnet ${fp(strongShorts.first.price)}');
  }

  if (fg != null) {
    if (fg < 25) {
      add(4, 'Fear and Greed $fg (extreme fear, contrarian buy zone)');
    } else if (fg > 80) {
      add(-5, 'Fear and Greed $fg (extreme greed)');
    }
  }
  if (oc != null && oc.m.isNotEmpty) {
    if (oc.score != 0) {
      add(oc.score * 3, 'On-chain: ${oc.notes.isNotEmpty ? oc.notes.first : 'bias'}');
    }
  }

  // plan
  double entry = (last - support) <= a ? last : support + 0.3 * a;
  double sl = math.min(support - 0.5 * a, entry - 1.2 * a);
  final risk = entry - sl;
  double tp1 = entry + 1.5 * risk;
  double tp2 = entry + 2.5 * risk;
  double tp3 = entry + 4.0 * risk;
  final mags = strongShorts.where((l) => l.price > tp1).map((l) => l.price).toList();
  if (mags.isNotEmpty) tp2 = mags.first;
  if (mags.length > 1) tp3 = math.max(mags[1], tp2 + 0.5 * risk);
  if (tp2 <= tp1) tp2 = tp1 + risk;
  if (tp3 <= tp2) tp3 = tp2 + risk;

  p.entry = entry;
  p.sl = sl;
  p.tp1 = tp1;
  p.tp2 = tp2;
  p.tp3 = tp3;
  p.rr = (tp2 - entry) / risk;

  if (down4 && (btcBear || base == 'BTC')) s = math.min(s, 54);
  s = s.clamp(0.0, 100.0).toDouble();
  p.score = s;
  if (s >= 70 && p.rr! >= 1.5) {
    p.action = entry == last ? 'BUY NOW' : 'LIMIT BUY (entry ka wait)';
  } else if (s >= 55) {
    p.action = 'WATCH (limit order only)';
  } else {
    p.action = 'WAIT (buy mat karo)';
  }
  return p;
}

// ---------------------------------------------------------------- app

class SpotSignalApp extends StatelessWidget {
  const SpotSignalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spot Signal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(backgroundColor: kBg),
        navigationBarTheme: const NavigationBarThemeData(backgroundColor: kCard),
      ),
      home: const Home(),
    );
  }
}

class Home extends StatelessWidget {
  const Home({super.key});

  void _settings(BuildContext context) {
    final cmc = TextEditingController(text: Settings.cmcKey);
    final gem = TextEditingController(text: Settings.geminiKey);
    final model = TextEditingController(text: Settings.geminiModel);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settings (keys sirf phone me save)'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: cmc,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'CoinMarketCap API key')),
            TextField(
                controller: gem,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Gemini API key')),
            TextField(
                controller: model,
                decoration: const InputDecoration(labelText: 'Gemini model')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              Settings.cmcKey = cmc.text.trim();
              Settings.geminiKey = gem.text.trim();
              Settings.geminiModel =
                  model.text.trim().isEmpty ? 'gemini-flash-latest' : model.text.trim();
              await Settings.save();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['Coins', 'Heatmap', 'Nodes', 'Chart', 'AI Signal'];
    return ListenableBuilder(
      listenable: Listenable.merge([tabIndex, selected]),
      builder: (context, _) {
        final i = tabIndex.value;
        return Scaffold(
          appBar: AppBar(
            title: Text('${titles[i]}  -  ${selected.value}'),
            actions: [
              IconButton(icon: const Icon(Icons.settings), onPressed: () => _settings(context)),
            ],
          ),
          body: IndexedStack(index: i, children: const [
            CoinsScreen(),
            HeatScreen(),
            NodeScreen(),
            TvScreen(),
            SignalScreen(),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: i,
            onDestinationSelected: (v) => tabIndex.value = v,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.list), label: 'Coins'),
              NavigationDestination(icon: Icon(Icons.grid_on), label: 'Heatmap'),
              NavigationDestination(icon: Icon(Icons.hub), label: 'Nodes'),
              NavigationDestination(icon: Icon(Icons.candlestick_chart), label: 'Chart'),
              NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'AI'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- coins tab

class CoinsScreen extends StatefulWidget {
  const CoinsScreen({super.key});
  @override
  State<CoinsScreen> createState() => _CoinsState();
}

class _CoinsState extends State<CoinsScreen> {
  List<Coin> coins = [];
  bool loading = true;
  String? err;
  String q = '';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      err = null;
    });
    try {
      coins = await Market.coins();
    } catch (e) {
      err = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final shown = coins.where((c) => c.symbol.contains(q.toUpperCase())).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search), hintText: 'Coin search (BTC, SOL...)'),
          onChanged: (v) => setState(() => q = v),
        ),
      ),
      if (loading) const LinearProgressIndicator(),
      if (err != null && coins.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Text('Error: $err', style: const TextStyle(color: kRed)),
            TextButton(onPressed: load, child: const Text('Retry')),
          ]),
        ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: load,
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (ctx, i) {
              final c = shown[i];
              final up = c.change >= 0;
              return ListTile(
                title: Text(c.symbol, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                    'Vol ${fb(c.volume)}${c.mcap != null ? '   MCap ${fb(c.mcap!)}' : ''}',
                    style: const TextStyle(fontSize: 12)),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(fp(c.price)),
                    Text('${up ? '+' : ''}${c.change.toStringAsFixed(2)}%',
                        style: TextStyle(color: up ? kGreen : kRed, fontSize: 12)),
                  ],
                ),
                selected: selected.value == c.symbol,
                onTap: () {
                  selected.value = c.symbol;
                  tabIndex.value = 1;
                },
              );
            },
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- heatmap tab

class HeatScreen extends StatefulWidget {
  const HeatScreen({super.key});
  @override
  State<HeatScreen> createState() => _HeatState();
}

class _HeatState extends State<HeatScreen> {
  String interval = '1h';
  HeatResult? res;
  Deriv? dv;
  bool loading = false;
  String? err;

  @override
  void initState() {
    super.initState();
    selected.addListener(load);
    load();
  }

  @override
  void dispose() {
    selected.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final sym = selected.value;
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final cf = Market.candles(sym, interval);
      final df = Market.deriv(sym, interval);
      final cs = await cf;
      final d = await df;
      if (sym != selected.value) return;
      dv = d;
      res = d.hist.isEmpty ? null : buildHeat(cs, d.hist, interval);
      if (d.hist.isEmpty) err = '$sym ka futures open interest data nahi mila (sirf spot coin ho sakta hai).';
    } catch (e) {
      err = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = res;
    final d = dv;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(
        children: ['15m', '1h', '4h']
            .map((iv) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(iv),
                    selected: interval == iv,
                    onSelected: (_) {
                      setState(() => interval = iv);
                      load();
                    },
                  ),
                ))
            .toList(),
      ),
      const SizedBox(height: 8),
      if (loading) const LinearProgressIndicator(),
      if (err != null) Text(err!, style: const TextStyle(color: kYellow)),
      if (r != null)
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Estimated liquidation heatmap - ${selected.value} ($interval)',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(
            height: 360,
            child: ClipRect(child: CustomPaint(size: Size.infinite, painter: HeatPainter(r))),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Container(width: 60, height: 8, color: heatColor(0.15)),
            const SizedBox(width: 6),
            const Text('kam', style: TextStyle(fontSize: 11)),
            const Spacer(),
            const Text('zyada liquidity', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 6),
            Container(width: 60, height: 8, color: heatColor(1)),
          ]),
          const SizedBox(height: 6),
          const Text(
              'Ye OI + leverage model se estimate hai, CoinGlass ka exact data nahi.',
              style: TextStyle(fontSize: 11, color: Colors.white54)),
        ])),
      if (r != null) ..._levelCards(r),
      if (d != null)
        card(Column(children: [
          kv('Binance OI', d.hist.isNotEmpty ? '\$${fb(d.hist.last[1])}' : 'n/a'),
          kv('Bybit OI', d.bybitOiUsd != null ? '\$${fb(d.bybitOiUsd!)}' : 'n/a'),
          kv('Funding Binance', d.funding != null ? '${(d.funding! * 100).toStringAsFixed(4)}%' : 'n/a'),
          kv('Funding Bybit',
              d.bybitFunding != null ? '${(d.bybitFunding! * 100).toStringAsFixed(4)}%' : 'n/a'),
          kv('Long/Short ratio', d.ls != null ? d.ls!.toStringAsFixed(2) : 'n/a'),
        ])),
    ]);
  }

  List<Widget> _levelCards(HeatResult r) {
    final last = r.candles.last.c;
    final lv = aliveLevels(r);
    final up = lv.where((l) => l.price > last && !l.isLong).toList()
      ..sort((a, b) => b.w.compareTo(a.w));
    final dn = lv.where((l) => l.price < last && l.isLong).toList()
      ..sort((a, b) => b.w.compareTo(a.w));
    Widget block(String title, List<Level> l, Color col) {
      final top = l.take(5).toList()..sort((a, b) => b.price.compareTo(a.price));
      return card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(color: col, fontWeight: FontWeight.bold)),
        for (final x in top) kv(fp(x.price), '\$${fb(x.w)}', c: col),
        if (top.isEmpty) const Text('koi zone nahi', style: TextStyle(color: Colors.white54)),
      ]));
    }

    return [
      block('Upar: short liquidation zones (price magnet)', up, kGreen),
      block('Neeche: long liquidation zones (support / sweep)', dn, kRed),
    ];
  }
}

// ---------------------------------------------------------------- nodes (on-chain) tab

class NodeScreen extends StatefulWidget {
  const NodeScreen({super.key});
  @override
  State<NodeScreen> createState() => _NodeState();
}

class _NodeState extends State<NodeScreen> {
  OnChain? oc;
  Deriv? dv;
  int? fg;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    selected.addListener(load);
    load();
  }

  @override
  void dispose() {
    selected.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final b = selected.value;
    setState(() => loading = true);
    try {
      fg = await Market.fng();
      oc = (b == 'BTC' || b == 'ETH') ? await Market.onchain(b.toLowerCase()) : null;
      dv = await Market.deriv(b, '1h');
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  String _chg(String k, OnChain o) {
    final a7 = o.avg(k, 7);
    final a30 = o.avg(k, 30);
    if (a7 == null || a30 == null || a30 == 0) return '';
    final p = (a7 / a30 - 1) * 100;
    return '  (7d vs 30d: ${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%)';
  }

  @override
  Widget build(BuildContext context) {
    final b = selected.value;
    final o = oc;
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (loading) const LinearProgressIndicator(),
      card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Market sentiment', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        kv('Fear and Greed', fg != null ? '$fg' : 'n/a',
            c: fg == null ? null : (fg! < 40 ? kRed : (fg! > 60 ? kGreen : kYellow))),
      ])),
      if (o != null)
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$b on-chain (free CoinMetrics)', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          kv('MVRV', o.last('CapMVRVCur')?.toStringAsFixed(2) ?? 'n/a'),
          kv('Active addresses',
              o.last('AdrActCnt') != null ? '${fb(o.last('AdrActCnt')!)}${_chg('AdrActCnt', o)}' : 'n/a'),
          kv('Transactions/day', o.last('TxCnt') != null ? fb(o.last('TxCnt')!) : 'n/a'),
          kv('NVT (adj)', o.last('NVTAdj')?.toStringAsFixed(1) ?? 'n/a'),
          const Divider(),
          kv('On-chain bias', o.score > 0 ? 'Bullish' : (o.score < 0 ? 'Bearish' : 'Neutral'),
              c: o.score > 0 ? kGreen : (o.score < 0 ? kRed : kYellow)),
          for (final n in o.notes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('- $n', style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ),
        ]))
      else
        card(const Text(
            'Is coin ka free on-chain data available nahi. Free on-chain sirf BTC aur ETH ka hai. Neeche derivatives nodes dekho.',
            style: TextStyle(color: Colors.white70))),
      if (dv != null)
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Derivatives nodes', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          kv('Open interest (Binance)', dv!.hist.isNotEmpty ? '\$${fb(dv!.hist.last[1])}' : 'n/a'),
          kv('Open interest (Bybit)', dv!.bybitOiUsd != null ? '\$${fb(dv!.bybitOiUsd!)}' : 'n/a'),
          kv('Funding', dv!.funding != null ? '${(dv!.funding! * 100).toStringAsFixed(4)}%' : 'n/a'),
          kv('Long/Short', dv!.ls != null ? dv!.ls!.toStringAsFixed(2) : 'n/a'),
        ])),
      const Text(
          'Exchange inflow/outflow aur whale flows (Glassnode jaise) free nahi hote, isliye yahan nahi hain.',
          style: TextStyle(fontSize: 11, color: Colors.white54)),
    ]);
  }
}

// ---------------------------------------------------------------- TradingView tab

class TvScreen extends StatefulWidget {
  const TvScreen({super.key});
  @override
  State<TvScreen> createState() => _TvState();
}

class _TvState extends State<TvScreen> {
  late final WebViewController ctrl;
  String iv = '60';

  @override
  void initState() {
    super.initState();
    ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(kBg);
    selected.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    selected.removeListener(_load);
    super.dispose();
  }

  void _load() {
    final sym = 'BINANCE:${selected.value}USDT';
    final html = '''
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0;padding:0;height:100%;background:#0b0e11}#tv{height:100vh;width:100vw}</style></head>
<body><div id="tv"></div>
<script src="https://s3.tradingview.com/tv.js"></script>
<script>
new TradingView.widget({autosize:true,symbol:"$sym",interval:"$iv",theme:"dark",style:"1",
locale:"en",toolbar_bg:"#0b0e11",enable_publishing:false,allow_symbol_change:true,
hide_side_toolbar:true,container_id:"tv"});
</script></body></html>''';
    ctrl.loadHtmlString(html, baseUrl: 'https://www.tradingview.com');
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: {'15': '15m', '60': '1h', '240': '4h', 'D': '1D'}
              .entries
              .map((e) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(e.value),
                      selected: iv == e.key,
                      onSelected: (_) {
                        setState(() => iv = e.key);
                        _load();
                      },
                    ),
                  ))
              .toList(),
        ),
      ),
      Expanded(child: WebViewWidget(controller: ctrl)),
    ]);
  }
}

// ---------------------------------------------------------------- AI signal tab

class SignalScreen extends StatefulWidget {
  const SignalScreen({super.key});
  @override
  State<SignalScreen> createState() => _SignalState();
}

class _SignalState extends State<SignalScreen> {
  Plan? plan;
  String? ai;
  String? err;
  String stage = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    selected.addListener(() {
      if (mounted) {
        setState(() {
          plan = null;
          ai = null;
          err = null;
        });
      }
    });
  }

  Future<void> run() async {
    final sym = selected.value;
    setState(() {
      busy = true;
      err = null;
      ai = null;
      plan = null;
    });
    try {
      final p = await analyze(sym, (s) {
        if (mounted) setState(() => stage = s);
      });
      if (mounted) setState(() => plan = p);
      if (Settings.geminiKey.isNotEmpty) {
        if (mounted) setState(() => stage = 'AI analysis...');
        final prompt = '''
You are a crypto SPOT trading analyst. Reply in Roman Urdu (Urdu written in English letters), short and clear, for a phone screen.
Below is a rule-based analysis computed from live Binance/Bybit/on-chain data. Use ONLY this data and do not invent numbers.
DATA: ${jsonEncode(p.toJson())}
Tasks:
1) Verdict: BUY or WAIT with one-line reason.
2) Confirm or slightly adjust entry, stop loss and TP1-TP3 (keep stop loss below the liquidity zone). Explain any change.
3) Main risks (max 3 bullets).
4) What would invalidate this trade.
Spot only, no shorting. End with: Ye financial advice nahi hai.
''';
        final txt = await Market.gemini(prompt);
        if (mounted) setState(() => ai = txt);
      }
    } catch (e) {
      if (mounted) setState(() => err = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = plan;
    final isBuy = p != null && p.action.startsWith('BUY') || (p?.action.startsWith('LIMIT') ?? false);
    final col = p == null ? kYellow : (isBuy ? kGreen : (p.action.startsWith('WATCH') ? kYellow : kRed));
    return ListView(padding: const EdgeInsets.all(12), children: [
      FilledButton.icon(
        onPressed: busy ? null : run,
        icon: const Icon(Icons.auto_awesome),
        label: Text('Analyze ${selected.value}'),
      ),
      const SizedBox(height: 8),
      if (busy) ...[
        const LinearProgressIndicator(),
        Padding(padding: const EdgeInsets.all(6), child: Text(stage)),
      ],
      if (err != null) Text(err!, style: const TextStyle(color: kRed)),
      if (p != null) ...[
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.action, style: TextStyle(color: col, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('Confluence score: ${p.score.round()} / 100'),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: p.score / 100, color: col, backgroundColor: Colors.white12),
          const SizedBox(height: 10),
          kv('Price', fp(p.price)),
          kv('Entry', fp(p.entry!), c: kYellow),
          kv('Stop loss', fp(p.sl!), c: kRed),
          kv('TP1', fp(p.tp1!), c: kGreen),
          kv('TP2', fp(p.tp2!), c: kGreen),
          kv('TP3', fp(p.tp3!), c: kGreen),
          kv('R:R (TP2)', p.rr!.toStringAsFixed(2)),
        ])),
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Bullish factors', style: TextStyle(color: kGreen, fontWeight: FontWeight.bold)),
          for (final x in p.pros) Text('+ $x', style: const TextStyle(fontSize: 13)),
          if (p.pros.isEmpty) const Text('-'),
          const SizedBox(height: 8),
          const Text('Bearish / risk factors', style: TextStyle(color: kRed, fontWeight: FontWeight.bold)),
          for (final x in p.cons) Text('- $x', style: const TextStyle(fontSize: 13)),
          if (p.cons.isEmpty) const Text('-'),
        ])),
      ],
      if (p != null && Settings.geminiKey.isEmpty)
        const Text('AI explanation ke liye Settings me Gemini API key daalo.',
            style: TextStyle(color: kYellow)),
      if (ai != null)
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('AI analysis', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SelectableText(ai!),
        ])),
      const Text(
          'Ye signals rules + estimated data par based hain. Koi bhi strategy profit guarantee nahi karti. Pehle chhote amount ya paper trade se test karo.',
          style: TextStyle(fontSize: 11, color: Colors.white54)),
    ]);
  }
}
