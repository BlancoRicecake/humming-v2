import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/screens/cloud_backup_screen.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:provider/provider.dart';
import 'support/fake_cloud.dart';
import 'support/offline_fonts.dart';
class _Store extends LoopStore {
  @override bool get isSignedIn=>true;
  @override bool get loaded=>true;
  void refreshForQa()=>notifyListeners();
}
void main(){
  final qaFontsAvailable=Platform.isWindows && File('C:/Windows/Fonts/segoeui.ttf').existsSync() && File('C:/Windows/Fonts/malgun.ttf').existsSync();
  setUpAll(() async {
      if (!qaFontsAvailable) return;
      await (FontLoader('QaActual')..addFont(File('C:/Windows/Fonts/segoeui.ttf').readAsBytes().then((b)=>ByteData.sublistView(b)))).load();
      await (FontLoader('QaKorean')..addFont(File('C:/Windows/Fonts/malgun.ttf').readAsBytes().then((b)=>ByteData.sublistView(b)))).load();
  });
  for(final c in [(320.0,'en',1.0),(320.0,'en',1.5),(320.0,'ko',1.0),(960.0,'ko',1.5)]){
    testWidgets('cloud list width ${c.$1} locale ${c.$2} text ${c.$3}',(tester)async{
      useOfflineTestFonts();

      await tester.binding.setSurfaceSize(Size(c.$1,640));
      addTearDown(()=>tester.binding.setSurfaceSize(null));
      final cloud=FakeCloud();
      cloud.rows['ltqa']={
        'project_id':'ltqa','title':'A complete song with recordings · 내 곡',
        'size_bytes':1024,'updated_at':'2026-10-30T09:00:00Z',
        'meta':{'format':'humtrack','key':'vocals/u/ltqa/bk-qa.humtrack',
        'size':1024,'sha256':'0'*64,'audioIncluded':true,'takes':2}
      };
      final api=fakeCloudApi(cloud);
      final store=_Store();
      await tester.pumpWidget(ChangeNotifierProvider<LoopStore>.value(value:store,
        child:MaterialApp(theme:ThemeData(fontFamily:'QaActual',fontFamilyFallback:['QaKorean']),locale:Locale(c.$2),localizationsDelegates:L10n.localizationsDelegates,
          supportedLocales:L10n.supportedLocales,
          builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(textScaler:TextScaler.linear(c.$3)),child:child!),
          home:CloudBackupScreen(api:api))));
      for(var i=0;i<40 && find.byKey(const ValueKey('cloud-usage')).evaluate().isEmpty;i++){
        await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:10)));
        await tester.pump(const Duration(milliseconds:10));
      }
      expect(find.byKey(const ValueKey('cloud-usage')),findsOneWidget);
      expect(tester.takeException(),isNull,reason:'cloud restore/delete buttons must fit');
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    }, skip: !qaFontsAvailable);
  }
  testWidgets('cached cloud list disappears when signed in account changes',(tester)async{
    useOfflineTestFonts();
    final store=_Store(),cloud=FakeCloud();
    var signedIn='user-a';
    cloud.rows['ltprivate']={
      'project_id':'ltprivate','title':'ACCOUNT_A_SECRET_TITLE','size_bytes':42,
      'updated_at':'2026-10-30T09:00:00Z',
      'meta':{'format':'humtrack','key':'vocals/u/ltprivate/bk-qa.humtrack',
        'size':42,'sha256':'0'*64,'audioIncluded':true,'takes':1}
    };
    final api=fakeCloudApi(cloud,owner:'user-a',signedIn:()=>signedIn);
    await tester.pumpWidget(ChangeNotifierProvider<LoopStore>.value(value:store,
      child:MaterialApp(locale:const Locale('en'),localizationsDelegates:L10n.localizationsDelegates,
        supportedLocales:L10n.supportedLocales,home:CloudBackupScreen(api:api))));
    for(var i=0;i<40 && find.text('ACCOUNT_A_SECRET_TITLE').evaluate().isEmpty;i++){
      await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:10)));
      await tester.pump(const Duration(milliseconds:10));
    }
    expect(find.text('ACCOUNT_A_SECRET_TITLE'),findsOneWidget);
    signedIn='user-b';
    store.refreshForQa();
    await tester.pump();
    expect(find.text('ACCOUNT_A_SECRET_TITLE'),findsNothing,reason:'cached account A data must not be visible under account B');
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}