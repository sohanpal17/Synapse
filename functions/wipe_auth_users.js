const admin = require('firebase-admin');

admin.initializeApp();

async function listAllUsers(nextPageToken, collected = []) {
  const result = await admin.auth().listUsers(1000, nextPageToken);
  const users = collected.concat(result.users.map((u) => u.uid));
  if (result.pageToken) {
    return listAllUsers(result.pageToken, users);
  }
  return users;
}

async function deleteAllUsers() {
  const uids = await listAllUsers();
  if (uids.length === 0) {
    console.log('No Auth users found.');
    return;
  }

  let deleted = 0;
  for (let i = 0; i < uids.length; i += 1000) {
    const chunk = uids.slice(i, i + 1000);
    const res = await admin.auth().deleteUsers(chunk);
    deleted += res.successCount;
    console.log(`Deleted ${deleted}/${uids.length} users...`);
    if (res.failureCount > 0) {
      console.error(`Failed deletions in batch: ${res.failureCount}`);
      res.errors.forEach((e) => {
        console.error(` - index ${e.index}: ${e.error?.message || e.error}`);
      });
    }
  }

  console.log(`Done. Deleted ${deleted} users total.`);
}

deleteAllUsers().catch((err) => {
  console.error('Auth wipe failed:', err);
  process.exit(1);
});
