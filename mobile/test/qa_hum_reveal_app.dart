// QA-only: the hum result reveal (QA 2026-10-30 follow-up). A copy of Codex's
// codex_hum_e2e_app.dart (synthetic 2 s D4 E4 F4 A4 WAV through the real hum
// modal -> real /analyze -> real editor insertion; no microphone, no personal
// data) that also records which piano-roll rows are on screen before and
// right after the conversion, without any scrolling.
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'ui005_beginner_polish_verify_app.dart' as lookup;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'QA_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\qa-fix-2026-10-30\reveal-check',
);

String _inside(String path) {
  final full = p.normalize(p.absolute(path));
  if (!p.isWithin(p.normalize(_workspace), full)) {
    throw StateError('QA path escapes $_workspace: $path -> $full');
  }
  return full;
}

class _QaPathProvider extends PathProviderPlatform {
  _QaPathProvider(this.dirs);
  final Map<String, String> dirs;
  @override
  Future<String?> getApplicationDocumentsPath() async => dirs['documents'];
  @override
  Future<String?> getApplicationSupportPath() async => dirs['support'];
  @override
  Future<String?> getApplicationCachePath() async => dirs['cache'];
  @override
  Future<String?> getTemporaryPath() async => dirs['temp'];
  @override
  Future<String?> getLibraryPath() async => dirs['library'];
  @override
  Future<String?> getDownloadsPath() async => dirs['downloads'];
  @override
  Future<String?> getExternalStoragePath() async => dirs['documents'];
  @override
  Future<List<String>?> getExternalCachePaths() async => [dirs['cache']!];
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => [dirs['documents']!];
}


// QA only: synthetic recorder input; real app, real EngineApi and note insertion.
// No physical microphone or personal files. OS X clicks are performed separately.
late AudioPlayer _closePlayer;
final Map<String, dynamic> report = {};
late File _reportFile;
Future<void> saveReport() => _reportFile.writeAsString(const JsonEncoder.withIndent('  ').convert(report));

Uint8List syntheticMelody() {
  const rate=16000, total=32000;
  final data=ByteData(44+total*2);
  void ascii(int at,String value){for(var i=0;i<value.length;i++){data.setUint8(at+i,value.codeUnitAt(i));}}
  ascii(0,'RIFF');data.setUint32(4,36+total*2,Endian.little);ascii(8,'WAVE');ascii(12,'fmt ');
  data.setUint32(16,16,Endian.little);data.setUint16(20,1,Endian.little);data.setUint16(22,1,Endian.little);
  data.setUint32(24,rate,Endian.little);data.setUint32(28,rate*2,Endian.little);data.setUint16(32,2,Endian.little);data.setUint16(34,16,Endian.little);
  ascii(36,'data');data.setUint32(40,total*2,Endian.little);
  const pitches=[62,64,65,69];
  for(var i=0;i<total;i++){
    final section=i~/8000;
    final t=(i%8000)/rate;
    final freq=440*math.pow(2,(pitches[section]-69)/12);
    final env=t<.38 ? math.min(1,math.min(t/.02,(.38-t)/.02)) : 0.0;
    final phase=2*math.pi*freq*t;
    final value=env*.5*(.70*math.sin(phase)+.20*math.sin(2*phase)+.10*math.sin(3*phase));
    data.setInt16(44+i*2,(32767*value).round().clamp(-32768,32767),Endian.little);
  }
  return data.buffer.asUint8List();
}

class _SyntheticRecorder extends RecordPlatform with MockPlatformInterfaceMixin {
  String? path;
  bool running=false;
  bool stopped=false;
  @override Future<void> create(String id) async {}
  @override Future<bool> hasPermission(String id,{bool request=true}) async=>true;
  @override Future<bool> isEncoderSupported(String id,AudioEncoder encoder) async=>encoder==AudioEncoder.wav;
  @override Future<void> start(String id,RecordConfig config,{required String path}) async {
    if(config.encoder!=AudioEncoder.wav)throw StateError('Expected fixed Windows WAV choice');
    this.path=_inside(path);
    await File(this.path!).writeAsBytes(syntheticMelody());
    running=true;
    report['recorder']={'substituted':true,'codec':config.encoder.name,'extension':p.extension(path),'sampleRate':config.sampleRate,'fixtureMidi':[62,64,65,69],'containsHumanAudio':false};
    await saveReport();
  }
  @override Future<String?> stop(String id) async {running=false;stopped=true;return path;}
  @override Future<void> dispose(String id) async {}
  @override Future<bool> isRecording(String id) async=>running;
  @override Future<bool> isPaused(String id) async=>false;
  @override Future<Amplitude> getAmplitude(String id) async=>Amplitude(current:-12,max:-12);
  @override Stream<RecordState> onStateChanged(String id)=>const Stream.empty();
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}

/// The piano-roll rows inside the viewport now (MIDI numbers, top first).
Map<String,Object?> _visibleRows(){
  final scroll=lookup.find<SingleChildScrollView>(const ValueKey('pitch-grid-viewport'))?.controller;
  final grid=lookup.find<StepGrid>();
  if(scroll==null||grid==null||!scroll.hasClients)return {'midis':<int>[]};
  final rows=grid.ladder.reversed.toList();
  final pos=scroll.position;
  final rowH=(pos.maxScrollExtent+pos.viewportDimension)/rows.length;
  final top=pos.pixels,bottom=top+pos.viewportDimension;
  final midis=[for(var i=0;i<rows.length;i++)if((i+1)*rowH>top&&i*rowH<bottom)rows[i].midi];
  return {'offset':pos.pixels,'midis':midis,'top':midis.isEmpty?null:midis.first,'bottom':midis.isEmpty?null:midis.last};
}

Future<void> main() async {
  final run=Platform.environment['QA_RUN']??'release';
  final root=_inside(p.join(_root,run));
  final dirs={for(final name in ['documents','support','cache','temp','library','downloads'])name:_inside(p.join(root,'data',name))};
  for(final value in dirs.values){await Directory(value).create(recursive:true);}
  if(!p.isWithin(_workspace,p.normalize(p.absolute(Directory.systemTemp.path))))throw StateError('TMP/TEMP must be isolated in repo');
  _reportFile=File(p.join(root,'result.json'));
  report.addAll({'mode':kReleaseMode?'release':'debug','status':'initializing','run':run,'input':'synthetic 2s D4 E4 F4 A4 WAV, not live microphone','scope':'Real product modal -> real backend /analyze -> real editor note insertion. Recorder replaced with generated fixture. Native close is a separate OS mouse action.','engineMocked':false,'personalDataAccess':false});
  final fake=_SyntheticRecorder();
  RecordPlatform.instance=fake;
  PathProviderPlatform.instance=_QaPathProvider(dirs);
  SharedPreferences.setMockInitialValues({});
  LoopStorage.rootOverride=Directory(dirs['documents']!);
  final errors=<String>[];
  try {
    await app.main();
    FlutterError.onError=(e){errors.add(e.exceptionAsString());};
    await Future<void>.delayed(const Duration(seconds:1));
    _closePlayer=AudioPlayer();
    await _closePlayer.setVolume(0); // exercise audioplayers plugin teardown, no sound
    await LoopPrefs.instance.setDesktopView('arrange');
    LoopPrefs.instance.metro.value=false;
    NavigatorState? navigator;
    void visit(Element e){if(e is StatefulElement && e.state is NavigatorState)navigator??=e.state as NavigatorState;e.visitChildren(visit);}
    visit(WidgetsBinding.instance.rootElement!);
    final section=Section(id:'qa',name:'QA',bars:1,autoName:false)..tracks['melody']=TrackData(notes:[]);
    final song=Song(id:'codex-synthetic-e2e',title:'QA · synthetic melody',bpm:120,bars:1,key:'D',scale:'dorian',sections:[section]);
    navigator!.push(MaterialPageRoute<void>(builder:(_)=>EditScreen(song:song)));
    await Future<void>.delayed(const Duration(milliseconds:1200));
    lookup.find<Arrangement>()!.onOpenTrack!('melody');
    await Future<void>.delayed(const Duration(milliseconds:600));
    lookup.tapOfText('그리드')?.call();
    lookup.tapOfText('Grid')?.call();
    await Future<void>.delayed(const Duration(milliseconds:500));
    final grid=lookup.find<StepGrid>()!;
    report['notesBefore']=grid.notes.length;
    report['visibleBefore']=_visibleRows();
    report['status']='ready';
    await saveReport();
    debugPrint('[qa-reveal] ready: $run');
    if(Platform.environment['QA_CONVERT']!='1')return;
    report['status']='converting';
    await saveReport();
    lookup.find<DesktopCommands>()!.hum!(); // in-app callback; not an OS input claim
    await Future<void>.delayed(const Duration(milliseconds:350));
    report['humModalOpened']=lookup.elementNamed('_HumModal')!=null;
    final deadline=DateTime.now().add(const Duration(seconds:105));
    while(DateTime.now().isBefore(deadline)){
      await Future<void>.delayed(const Duration(milliseconds:500));
      final nowGrid=lookup.find<StepGrid>();
      if(nowGrid!=null && nowGrid.notes.isNotEmpty)break;
      if(fake.stopped && lookup.elementNamed('_HumModal')==null)break;
    }
    await Future<void>.delayed(const Duration(milliseconds:600));
    final notes=lookup.find<StepGrid>()?.notes??[];
    report['notesAfter']=notes.length;
    // no scrolling by this app: only the editor's own reveal may move the roll
    final visible=_visibleRows();
    report['visibleAfter']=visible;
    report['noteMidis']=[for(final n in notes)n.midi];
    report['notesOnScreenWithoutScrolling']=notes.isNotEmpty && notes.every((n)=>(visible['midis'] as List).contains(n.midi));
    report['notes']=[for(final n in notes)n.toJson()];
    report['allInKey']=notes.every((n)=>{0,2,4,5,7,9,11}.contains(n.midi%12));
    report['allInLoop']=notes.every((n)=>n.startSteps>=0 && n.startSteps<16 && (n.durationSteps ?? n.dur)>0 && n.startSteps+(n.durationSteps ?? n.dur)<=16);
    report['recordingStopped']=fake.stopped;
    report['temporaryTakeDeleted']=fake.path!=null && !File(fake.path!).existsSync();
    report['flutterErrors']=errors;
    report['passed']=report['humModalOpened']==true && fake.stopped && notes.isNotEmpty && report['allInKey']==true && report['allInLoop']==true && report['notesOnScreenWithoutScrolling']==true && errors.isEmpty;
    report['status']=report['passed']==true?'passed':'failed';
    await saveReport();
    debugPrint('[qa-reveal] result: ${report['status']}, notes=${notes.length}');
  } catch(e,s) {
    report['status']='failed';report['errorType']=e.runtimeType.toString();report['error']=e.toString();report['stack']=s.toString().split('\n').take(8).join('\n');report['flutterErrors']=errors;await saveReport();debugPrint('[qa-reveal] failed: ${e.runtimeType}');
  }
  // Keep open. Native X close will exercise engine destruction, not dart:io exit().
}
