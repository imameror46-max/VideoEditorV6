import 'dart:io';
import 'dart:math';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'models.dart';

const kFps = 30;
const _swEnc = ['-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '24', '-pix_fmt', 'yuv420p'];

class Info {
  final double dur, w, h;
  Info(this.dur, this.w, this.h);
}

Future<Info> probeInfo(String path) async {
  try {
    final s = await FFprobeKit.getMediaInformation(path);
    final dynamic info = await s.getMediaInformation();
    final dur = double.tryParse('${info?.getDuration()}') ?? 0;
    double w = 0, h = 0;
    final dynamic streams = info?.getStreams();
    if (streams != null) {
      for (final dynamic st in streams) {
        if ('${st.getType()}' != 'video') continue;
        w = double.tryParse('${st.getWidth()}') ?? 0;
        h = double.tryParse('${st.getHeight()}') ?? 0;
        var rot = 0.0;
        try {
          final dynamic props = st.getAllProperties();
          final sd = props?['side_data_list'];
          if (sd is List) {
            for (final e in sd) {
              if (e is Map && e['rotation'] != null) rot = double.tryParse('${e['rotation']}') ?? rot;
            }
          }
          final tags = props?['tags'];
          if (tags is Map && tags['rotate'] != null) rot = double.tryParse('${tags['rotate']}') ?? rot;
        } catch (_) {}
        if (rot.abs() % 180 == 90) {
          final t = w;
          w = h;
          h = t;
        }
        break;
      }
    }
    return Info(dur, w, h);
  } catch (_) {
    return Info(0, 0, 0);
  }
}

Future<double> probeDuration(String path) async => (await probeInfo(path)).dur;

Future<void> cancelRender() => FFmpegKit.cancel();

Future<void> _run(List<String> args) async {
  final s = await FFmpegKit.executeWithArguments(args);
  final rc = await s.getReturnCode();
  if (ReturnCode.isSuccess(rc)) return;
  if (ReturnCode.isCancel(rc)) throw Exception('Dibatalkan');
  final out = (await s.getOutput()) ?? '';
  throw Exception(out.length > 700 ? out.substring(out.length - 700) : out);
}

/// Coba encoder hardware HP (jauh lebih cepat); kalau gagal pakai x264 ultrafast.
Future<List<String>> _pickEncoder(Directory dir, int w, int h) async {
  try {
    final s = await FFmpegKit.executeWithArguments([
      '-y', '-f', 'lavfi', '-i', 'color=c=black:s=320x240:r=30:d=0.5',
      '-c:v', 'h264_mediacodec', '-b:v', '2M', '-pix_fmt', 'yuv420p',
      '${dir.path}/enc_test.mp4'
    ]);
    if (ReturnCode.isSuccess(await s.getReturnCode())) {
      final bps = (w * h * kFps * 0.12).round();
      return ['-c:v', 'h264_mediacodec', '-b:v', '$bps', '-pix_fmt', 'yuv420p'];
    }
  } catch (_) {}
  return _swEnc;
}

class Cell {
  final double cx, cy, bw, bh;
  Cell(this.cx, this.cy, this.bw, this.bh);
}

/// Mode otomatis: kalau bentuk media mirip bentuk kotak (potongan <= 30%), isi penuh; selain itu tampil utuh.
bool useCover(Opts o, Media m, double cw, double ch, bool multi) {
  if (o.mode == 0) return false;
  if (o.mode == 2) return true;
  if (!multi || m.w <= 0 || m.h <= 0) return false;
  final a = m.w / m.h, c = cw / ch;
  return 1 - min(a, c) / max(a, c) <= 0.3;
}

/// Urutan posisi: kiri-bawah -> kanan -> baris di atasnya (kiri -> kanan).
List<Cell> layout(Fmt f, List<Media> g) {
  final w = f.w.toDouble(), h = f.h.toDouble();
  final n = g.first.multi;
  if (n == 1) {
    final z = g.first.zoom;
    return [Cell(w / 2, h / 2, w * kMargin * z, h * kMargin * z)];
  }
  final grid = bestGrid(f, g);
  final cols = grid[0], rows = grid[1];
  final iw = w * kMarginMulti, ih = h * kMarginMulti;
  final ox = (w - iw) / 2, oy = (h - ih) / 2;
  final cw = (iw - kGap * (cols - 1)) / cols;
  final ch = (ih - kGap * (rows - 1)) / rows;
  return [
    for (var k = 0; k < g.length; k++)
      Cell(ox + (k % cols) * (cw + kGap) + cw / 2,
          oy + (rows - 1 - k ~/ cols) * (ch + kGap) + ch / 2, cw, ch)
  ];
}

Future<String> renderVideo({
  required Fmt fmt,
  required List<Media> items,
  required Bg bg,
  required List<Sound> sounds,
  required double total,
  required bool auto,
  required double manualDur,
  required Opts opts,
  required void Function(String msg, double v) onProgress,
}) async {
  final cf = scaleFmt(fmt, kQuality[opts.quality]);
  final frames = buildFrames(items);
  final u = auto ? total / items.length : manualDur; // durasi tiap foto/video
  final t = u * items.length;
  final tmp = await getTemporaryDirectory();
  final dir = Directory('${tmp.path}/render');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final w = cf.w, h = cf.h;
  String s3(double v) => v.toStringAsFixed(3);

  Future<List<String>> makeSegs(List<String> enc) async {
    final segs = <String>[];
    for (var f = 0; f < frames.length; f++) {
      onProgress('Frame ${f + 1} dari ${frames.length}', f / (frames.length + 1));
      final g = frames[f];
      final dd = u * g.length; // lama frame = jumlah media x durasi per media
      final args = <String>['-y'];
      if (bg.image != null) {
        args.addAll(['-framerate', '$kFps', '-i', bg.image!]);
      } else {
        final c = (bg.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
        args.addAll(['-f', 'lavfi', '-t', s3(dd), '-i', 'color=c=0x$c:s=${w}x$h:r=$kFps']);
      }
      for (final m in g) {
        if (m.isVideo) {
          args.addAll(['-i', m.path]);
        } else {
          args.addAll(['-framerate', '$kFps', '-i', m.path]); // foto dibaca sekali
        }
      }
      final fc = StringBuffer();
      fc.write(bg.image != null
          ? '[0:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,format=yuv420p,'
              'tpad=stop_mode=clone:stop_duration=${s3(dd)},fps=$kFps[bg0];'
          : '[0:v]setsar=1,format=yuv420p[bg0];');
      final cells = layout(cf, g);
      var prev = 'bg0';
      for (var k = 0; k < g.length; k++) {
        final m = g[k], c = cells[k];
        // Media ke-k mulai tampil setelah media sebelumnya selesai (ts),
        // diputar selama u detik, lalu bertahan di frame terakhir sampai frame berakhir.
        final ts = k * u;
        final r = (m.isVideo && m.dur > 0) ? u / m.dur : 1.0;
        final rem = dd - ts - u;
        final fi = min(0.5, u / 4), fo = min(0.5, dd / 8);
        final bw = ev(c.bw), bh = ev(c.bh);
        final fit = useCover(opts, m, c.bw, c.bh, g.length > 1 || g.first.multi > 1)
            ? 'scale=$bw:$bh:force_original_aspect_ratio=increase,crop=$bw:$bh'
            : 'scale=$bw:$bh:force_original_aspect_ratio=decrease:force_divisible_by=2';
        final fades = 'fade=t=in:st=${s3(ts)}:d=${s3(fi)}:alpha=1,fade=t=out:st=${s3(dd - fo)}:d=${s3(fo)}:alpha=1';
        final hold = rem > 0.01 ? 'tpad=stop_mode=clone:stop_duration=${s3(rem)},' : '';
        final chain = m.isVideo
            ? 'setpts=(PTS-STARTPTS)*${r.toStringAsFixed(5)}+${s3(ts)}/TB,fps=$kFps,$fit,setsar=1,format=yuva420p,$hold$fades'
            : '$fit,setsar=1,format=yuva420p,tpad=stop_mode=clone:stop_duration=${s3(dd)},'
                'setpts=PTS-STARTPTS+${s3(ts)}/TB,fps=$kFps,$fades';
        fc.write('[${k + 1}:v]$chain[m$k];');
        fc.write('[$prev][m$k]overlay=x=${c.cx.toStringAsFixed(1)}-w/2:'
            'y=${c.cy.toStringAsFixed(1)}-h/2:eof_action=pass[o$k];');
        prev = 'o$k';
      }
      var graph = fc.toString();
      graph = graph.substring(0, graph.length - 1);
      final out = '${dir.path}/seg$f.mp4';
      args.addAll(['-filter_complex', graph, '-map', '[$prev]', '-t', s3(dd), '-r', '$kFps', '-an', ...enc, out]);
      await _run(args);
      segs.add(out);
    }
    return segs;
  }

  onProgress('Menyiapkan encoder…', 0);
  final enc = await _pickEncoder(dir, w, h);
  List<String> segs;
  try {
    segs = await makeSegs(enc);
  } catch (e) {
    if (e.toString().contains('Dibatalkan') || enc.contains('libx264')) rethrow;
    segs = await makeSegs(_swEnc); // encoder hardware gagal -> ulangi dengan x264
  }

  onProgress('Menggabungkan frame…', frames.length / (frames.length + 1));
  File('${dir.path}/list.txt').writeAsStringSync(segs.map((p) => "file '$p'").join('\n'));
  final joined = '${dir.path}/joined.mp4';
  await _run(['-y', '-f', 'concat', '-safe', '0', '-i', '${dir.path}/list.txt', '-c', 'copy', joined]);

  final result = '${tmp.path}/Gabung_${DateTime.now().millisecondsSinceEpoch}.mp4';
  final used = sounds.where((s) => min(s.stop, t) - s.start > 0).toList();
  if (used.isEmpty) {
    File(joined).copySync(result);
  } else {
    onProgress('Memasang suara…', 0.97);
    final args = <String>['-y', '-i', joined];
    final fc = StringBuffer();
    for (var k = 0; k < used.length; k++) {
      final s = used[k];
      args.addAll(['-i', s.path]);
      final len = min(s.stop, t) - s.start;
      final ms = (s.start * 1000).round();
      fc.write('[${k + 1}:a]atrim=0:${s3(len)},asetpts=PTS-STARTPTS,adelay=$ms|$ms[a$k];');
    }
    for (var k = 0; k < used.length; k++) {
      fc.write('[a$k]');
    }
    fc.write('amix=inputs=${used.length}:duration=longest:normalize=0[aout]');
    args.addAll(['-filter_complex', fc.toString(), '-map', '0:v', '-map', '[aout]',
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-t', s3(t), result]);
    await _run(args);
  }
  await Gal.putVideo(result);
  onProgress('Selesai', 1);
  return result;
}
