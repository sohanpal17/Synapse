/* eslint-disable no-undef */
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyCz-A8KbOVZjqVQcnFlljKG5_I3aHFAc9k',
  authDomain: 'synapsetry.firebaseapp.com',
  projectId: 'synapsetry',
  storageBucket: 'synapsetry.firebasestorage.app',
  messagingSenderId: '424793428116',
  appId: '1:424793428116:web:f2df49a8d83860dabf6481',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  const notification = payload.notification || {};
  const title = notification.title || 'Synapse';
  const options = {
    body: notification.body || '',
    icon: '/icons/Icon-192.png',
    data: payload.data || {},
  };
  self.registration.showNotification(title, options);
});
