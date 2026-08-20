# Ghost Chat 👻

A secret two-person chat hidden inside a calculator app.  
Built with vanilla HTML/JS + **Supabase** for real-time messaging and file storage.

## Features
- 🔢 Calculator disguise — enter `12345 =` to open the chat
- 💬 Real-time messaging via Supabase Realtime
- 🗑 Delete your own messages (syncs instantly)
- 📎 File & image sharing (up to 50 MB)
- 🖼 Inline image previews with lightbox
- 🟢 Live online/offline presence

## Setup

### 1. Supabase
1. Create a project at [supabase.com](https://supabase.com)
2. Run `supabase_setup.sql` in the **SQL Editor**
3. Copy your **Project URL** and **anon key** from Settings → API

### 2. Configure
Edit `index.html` and replace:
```js
const SUPABASE_URL  = 'https://your-project.supabase.co';
const SUPABASE_ANON = 'your-anon-key';
```

### 3. Deploy to Vercel
1. Push to GitHub
2. Import repo at [vercel.com/new](https://vercel.com/new)
3. Framework: **Other** (static)
4. Deploy — done ✅

## Local Dev
```bash
npx serve .
```
