# Setting up cloud backup (Supabase)

The app works fully offline without this. Do these steps once to turn on backup and restore.
Dashboard labels change from time to time, so a label here may look slightly different on your screen.

## 1. Create a free Supabase project

1. Sign in at [supabase.com/dashboard](https://supabase.com/dashboard) and click **New project**.
2. Pick the free plan, give it a name (e.g. "workout-tracker"), set a database password (save it in your password manager) and choose the region nearest to you.
3. Wait a minute or two while it starts.

## 2. Create the tables

Use **one** of these.

**A. SQL editor (easiest)**
1. In the left sidebar open **SQL Editor** and start a new query.
2. Open `supabase/migrations/20261121000000_initial_schema.sql` from this repo, copy the whole file, paste it in and click **Run**.
3. Open **Table Editor**. You should see 7 tables (`exercises`, `routines`, …), each marked as having RLS enabled.

**B. Supabase CLI**
```sh
supabase login
supabase link --project-ref YOUR-PROJECT-REF   # the "abcd1234" part of https://abcd1234.supabase.co
supabase db push                               # asks for the database password from step 1
```

## 3. Turn on Sign in with Apple

1. Go to **Authentication › Providers** (it may be under **Authentication › Sign In / Providers**) and open **Apple**.
2. Switch it on.
3. In **Client IDs**, enter the app's bundle id: `com.ritikahotwani.workouttracker`
4. Click **Save**.

That's all the iPhone app needs. The **Services ID**, **Team ID**, **Key ID** and **secret key (.p8)** fields are only for signing in on a website (web OAuth), so leave them empty.

## 4. Give Xcode your Apple team

The Sign in with Apple capability only works in a build signed with your Apple developer team.
Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under **Membership details** (10 characters, e.g. `AB12CD34EF`), or in Xcode › Settings › Accounts. You'll put it in `Secrets.xcconfig` in step 6.

## 5. Find your project URL and key

- Click **Connect** at the top of the project dashboard. It shows the **Project URL** (`https://abcd1234.supabase.co`) and the key.
- Or open **Project Settings › API Keys** (older dashboards: **Project Settings › API** or **Data API**).

Use the **publishable** key (starts with `sb_publishable_`). On older projects it may be labelled **anon** / **public** (a long `eyJ…` string). Either works.

Never use the **secret** or **service_role** key in the app. It bypasses all security rules.

## 6. Fill in `Config/Secrets.xcconfig`

If it doesn't exist yet, copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`. It is git-ignored, so it never gets committed. Then set:

```
SUPABASE_URL = https:/$()/abcd1234.supabase.co
SUPABASE_ANON_KEY = sb_publishable_xxxxxxxxxxxxxxxx
DEVELOPMENT_TEAM = AB12CD34EF
```

Type the URL exactly like that, with `https:/$()/` in place of `https://`. In xcconfig files `//` starts a comment, and the empty `$()` stops that from happening.

Then in Xcode do **Product › Clean Build Folder** and run the app on your iPhone.

## 7. Check it works

1. Settings › Account › **Sign in with Apple**. While your data downloads, Settings shows "Restoring…".
2. Tap **Back Up Now**. "Last backup" should say "now".
3. In the dashboard's **Table Editor** you should see your rows.
4. To test restore: delete the app, reinstall it and sign in again. Your history comes back.

If Settings still says "Backup isn't set up yet", the URL or key didn't reach the app. Check for typos in `Secrets.xcconfig`, then clean and rebuild.
