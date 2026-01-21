// Import and configure the Firebase SDK
// This is a separate file from the main app's JavaScript
importScripts('https://www.gstatic.com/firebasejs/9.2.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/9.2.0/firebase-messaging-compat.js');

// Initialize the Firebase app in the service worker by passing in the
// configuration from your firebase_options.dart file.
firebase.initializeApp({
    apiKey: "AIzaSyAYRz0GiponFsPNuXDYBMHR9uNHQ8mgaS0",
    authDomain: "backpack-ba3ca.firebaseapp.com",
    projectId: "backpack-ba3ca",
    storageBucket: "backpack-ba3ca.appspot.com",
    messagingSenderId: "859349806124",
    appId: "1:859349806124:web:6e3ab0532763916b7e7589",
    measurementId: "G-KCNRKXQHKN"
});

// Retrieve an instance of Firebase Messaging so that it can handle background
// messages.
const messaging = firebase.messaging();

messaging.onBackgroundMessage(function(payload) {
  console.log('[firebase-messaging-sw.js] Received background message ', payload);
  // Customize notification here
  const notificationTitle = payload.notification.title;
  const notificationOptions = {
    body: payload.notification.body,
    icon: '/icons/Icon-192.png'
  };

  self.registration.showNotification(notificationTitle,
    notificationOptions);
});