import 'dart:math';
import 'package:flutter/widgets.dart';

class Fmt {
  final String label;
  final int w, h;
  const Fmt(this.label, this.w, this.h);
}

const formats = [
  Fmt('9:16', 720, 1280),
  Fmt('16:9', 1280, 720),
  Fmt('21:9', 1260, 540),
  Fmt('1:1', 720, 720),
];

const kMaxItems = 40;
const kMargin = 0.88;
const kMarginMulti = 0.96; // frame multi: hampir memenuhi kanvas
const kGap = 8.0;
const kQuality = [0.67, 1.0, 1.5]; // Cepat, Standar, Tinggi

int ev(num v) {
  final x = (v / 2).round() * 2;
  return x < 2 ? 2 : x;
}

Fmt scaleFmt(Fmt f, double s) => Fmt(f.label, ev(f.w * s), ev(f.h * s));

class Opts {
  int quality = 1;
  int mode = 1; // 0 = utuh, 1 = otomatis, 2 = penuh (dipotong)
}

class Media {
  final String path;
  final bool isVideo;
  final double dur;
  double w = 0, h = 0; // ukuran tampil (setelah rotasi), 0 = tidak diketahui
  int multi = 1;
  double zoom = 1.0;
  final Key key = UniqueKey();
  Media(this.path, this.isVideo, this.dur);
}

class Sound {
  final String path, name;
  final double len;
  double start = 0;
  late double stop;
  Sound(this.path, this.name, this.len) {
    stop = len;
  }
}

class Bg {
  int color = 0xFFFFFFFF;
  String? image;
}

bool isVideoPath(String p) {
  final e = p.split('.').last.toLowerCase();
  return const ['mp4', 'mov', 'mkv', 'webm', '3gp', 'avi', 'm4v'].contains(e);
}

/// Memilih susunan kolom x baris yang paling besar menampilkan media
/// (misal 4 video portrait di kanvas 16:9 jadi 4 kolom 1 baris).
List<int> bestGrid(Fmt f, List<Media> g) {
  final n = g.first.multi;
  final land = f.w >= f.h;
  // Kanvas lebar: 2-4 media berjejer 1 baris, 6-8 media 2 baris.
  final Map<int, List<List<int>>> options = land
      ? {
          1: [[1, 1]],
          2: [[2, 1]],
          4: [[4, 1], [2, 2]],
          6: [[3, 2]],
          8: [[4, 2]],
        }
      : {
          1: [[1, 1]],
          2: [[2, 1], [1, 2]],
          4: [[2, 2], [1, 4], [4, 1]],
          6: [[2, 3], [3, 2]],
          8: [[2, 4], [4, 2]],
        };
  final cands = options[n] ?? [[1, 1]];
  var a = 0.0, c = 0;
  for (final m in g) {
    if (m.w > 0 && m.h > 0) {
      a += m.w / m.h;
      c++;
    }
  }
  final asp = c == 0 ? 9 / 16 : a / c;
  var best = cands.first;
  var bestScore = -1.0;
  for (var i = 0; i < cands.length; i++) {
    final o = cands[i];
    final cw = (f.w * kMarginMulti - kGap * (o[0] - 1)) / o[0];
    final ch = (f.h * kMarginMulti - kGap * (o[1] - 1)) / o[1];
    final w = min(cw, ch * asp);
    final area = w * (w / asp) * (i == 0 ? 1.5 : 1.0); // pilihan pertama diutamakan
    if (area > bestScore) {
      bestScore = area;
      best = o;
    }
  }
  return best;
}

List<List<Media>> buildFrames(List<Media> items) {
  final out = <List<Media>>[];
  var i = 0;
  while (i < items.length) {
    final n = items[i].multi < 1 ? 1 : items[i].multi;
    final end = min(i + n, items.length);
    out.add(items.sublist(i, end));
    i = end;
  }
  return out;
}

String fmtTime(double s) {
  final t = s.round();
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

double parseTime(String s, double fallback) {
  try {
    var v = 0.0;
    for (final x in s.trim().split(':')) {
      v = v * 60 + double.parse(x);
    }
    return v;
  } catch (_) {
    return fallback;
  }
}
