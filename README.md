# LanHop (Windows + Android)
1. Install Flutter. In this folder run:  flutter create --platforms=windows,android --project-name lanhop .
2. Android only: in android/app/src/main/AndroidManifest.xml add, inside <manifest>:
   <uses-permission android:name="android.permission.INTERNET"/>
   <queries><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="http"/></intent></queries>
3. flutter pub get
4. Run:  flutter run -d windows   |   flutter build apk --release   |   flutter build windows --release
Windows will ask to allow the firewall the first time: allow "Private networks".
