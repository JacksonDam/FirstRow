import Foundation

/// Runs inside Spotify's web player page, which First Row keeps out of sight and plays through.
/// It reaches the page's own services (player, library, playlists) and answers First Row's calls.
///
/// First Row calls `window.firstRowSpotify.call(id, name, args)`. The page answers with JSON text
/// sent to `webkit.messageHandlers.firstRowSpotify` on the Mac, or `firstRowSpotifyPost` in Chrome:
/// `{type: "ready", signedIn, name}`, `{type: "state", state}` and `{type: "result", id, ok, value | error}`.
let spotifyBridgeScript = #"""
(() => {
  // Sign-in pages get nothing: the bridge is for the player.
  if (location.hostname !== 'open.spotify.com') return;
  if (window.firstRowSpotify) {
    window.firstRowSpotify.announce();
    return;
  }

  const send = message => {
    const text = JSON.stringify(message);
    try {
      const handlers = window.webkit && window.webkit.messageHandlers;
      if (handlers && handlers.firstRowSpotify) return handlers.firstRowSpotify.postMessage(text);
      if (typeof window.firstRowSpotifyPost === 'function') return window.firstRowSpotifyPost(text);
    } catch (e) {}
  };

  // The page is never on screen, but it should run as if it were: browsers slow the timers of
  // pages they think are hidden, and the player keeps time with them.
  try {
    Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get: () => false });
    Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: () => 'visible' });
    for (const target of [document, window]) {
      target.addEventListener('visibilitychange', event => event.stopImmediatePropagation(), true);
    }
  } catch (e) {}

  // The page keeps its services in a registry handed down React's tree as a context value.
  const findPlatform = () => {
    const root = document.getElementById('main') || document.body;
    if (!root) return null;
    for (const element of [root, ...root.querySelectorAll('div')]) {
      const key = Object.keys(element).find(name => name.startsWith('__reactContainer$'));
      if (!key) continue;
      const fibers = [element[key]];
      while (fibers.length) {
        const fiber = fibers.pop();
        const value = fiber && fiber.memoizedProps && fiber.memoizedProps.value;
        if (value && typeof value === 'object' && typeof value.getRegistry === 'function') return value;
        if (fiber && fiber.child) fibers.push(fiber.child);
        if (fiber && fiber.sibling) fibers.push(fiber.sibling);
      }
    }
    return null;
  };

  let platform = null;
  const symbols = {};
  const service = name => {
    if (!platform) throw new Error('Spotify is still loading');
    if (!symbols[name]) throw new Error('Spotify has no ' + name);
    return platform.getRegistry().resolve(symbols[name]);
  };

  // GraphQL requests the page makes are named and hashed in its scripts, and the hashes change
  // with each version of the page, so they're read from the scripts it loaded.
  let operations = null;
  const operation = async name => {
    if (!operations) {
      const found = {};
      const scripts = [...document.scripts].map(script => script.src).filter(src => /\/web-player\/[^/]+\.js$/.test(src));
      for (const src of scripts) {
        try {
          const text = await (await fetch(src)).text();
          for (const match of text.matchAll(/\("(\w+)","(query|mutation)","([0-9a-f]{64})"/g)) {
            found[match[1]] = { name: match[1], operation: match[2], sha256Hash: match[3], value: null };
          }
        } catch (e) {}
      }
      operations = found;
    }
    if (!operations[name]) throw new Error('Spotify no longer answers ' + name);
    return operations[name];
  };
  const query = async (name, variables) => {
    const result = await platform.getGraphQLLoader()(await operation(name), variables);
    if (!result || !result.data) {
      const error = result && result.errors && result.errors[0];
      throw new Error(error && error.message || name + ' failed');
    }
    return result.data;
  };

  // The biggest picture. Without sizes, Spotify's 640-pixel covers have "b273" in their names.
  const largestImage = images => {
    const list = (images || []).filter(image => image && image.url);
    if (!list.length) return null;
    if (!list.some(image => image.width)) return (list.find(image => /0000b273/.test(image.url)) || list[0]).url;
    return list.reduce((best, image) => (image.width || 0) > (best.width || 0) ? image : best).url;
  };
  const names = list => (list || []).map(item => item && (item.name || (item.profile && item.profile.name))).filter(Boolean);

  // One track shape for every source. `album` is passed in where the rows don't carry it.
  const track = (item, album) => {
    if (!item || !item.uri || !/^spotify:(track|episode):/.test(item.uri)) return null;
    const artists = Array.isArray(item.artists) ? names(item.artists) : names(item.artists && item.artists.items);
    const ownAlbum = item.album || item.albumOfTrack;
    const duration = item.duration ? (item.duration.milliseconds || item.duration.totalMilliseconds || 0) : 0;
    const playable = item.playability ? item.playability.playable !== false : item.isPlayable !== false;
    return {
      uri: item.uri,
      name: item.name || '',
      artist: artists.join(', '),
      album: (ownAlbum && ownAlbum.name) || (album && album.name) || '',
      image: largestImage(ownAlbum && (ownAlbum.images || (ownAlbum.coverArt && ownAlbum.coverArt.sources))) || (album && album.image) || null,
      durationMs: duration,
      trackNumber: item.trackNumber || 0,
      discNumber: item.discNumber || 1,
      playable,
    };
  };

  const isAdvert = item => !!item && (item.type === 'ad' || /^spotify:ad:/.test(item.uri || '') || item.provider === 'ad' || !!item.advertiser);
  const playerState = () => {
    const state = service('PlayerAPI').getState();
    if (!state || !state.item) return null;
    const item = state.item;
    const mapped = track(item) || { uri: item.uri || '', name: item.name || item.title || '', artist: names(item.artists).join(', '), album: '', image: largestImage(item.images), durationMs: 0 };
    return {
      ...mapped,
      advert: isAdvert(item),
      advertiser: item.advertiser || '',
      paused: !!state.isPaused,
      buffering: !!state.isBuffering,
      positionMs: state.positionAsOfTimestamp || 0,
      timestamp: state.timestamp || Date.now(),
      now: Date.now(),
      durationMs: state.duration || mapped.durationMs || 0,
      contextUri: state.context ? state.context.uri : null,
    };
  };

  // Reads pages of a list until it's all there.
  const allPages = async (read, pageSize, limit) => {
    const items = [];
    for (let offset = 0; offset < limit;) {
      const page = await read(offset, pageSize);
      const rows = page.rows || [];
      items.push(...rows);
      offset += rows.length;
      if (!rows.length || offset >= (page.total || 0)) break;
    }
    return items;
  };

  const collection = (item, subtitle) => item && item.uri && {
    uri: item.uri,
    name: item.name || '',
    subtitle: subtitle || '',
    image: largestImage(item.images),
  };

  const commands = {
    account: async () => {
      const token = await service('TokenProvider').getToken();
      let user = null;
      try { user = await service('UserAPI').getUser(); } catch (e) {}
      return {
        signedIn: !!token && !token.isAnonymous,
        name: (user && (user.displayName || user.username)) || '',
        username: (user && user.username) || '',
      };
    },

    playlists: async () => {
      const contents = await service('RootlistAPI').getContents();
      const out = [];
      const walk = items => {
        for (const item of items || []) {
          if (item.type === 'folder') walk(item.items);
          else if (/^spotify:playlist:/.test(item.uri || '')) out.push(collection(item, item.owner && (item.owner.displayName || item.owner.name)));
        }
      };
      walk(contents && contents.items);
      return out;
    },

    // Saved albums ("Albums") or followed artists ("Artists").
    library: async args => {
      const rows = await allPages(async (offset, limit) => {
        const page = await service('LibraryAPI').getContents({ filters: [args.filter], offset, limit });
        return { rows: page.items || [], total: page.totalLength || 0 };
      }, 50, 2000);
      return rows.map(item => collection(item, item.artists ? names(item.artists).join(', ') : '')).filter(Boolean);
    },

    likedSongs: async () => {
      const rows = await allPages(async (offset, limit) => {
        const page = await service('LibraryAPI').getTracks({ offset, limit });
        return { rows: page.items || [], total: page.totalLength || 0 };
      }, 50, 10000);
      return rows.map(item => track(item)).filter(Boolean);
    },

    playlistTracks: async args => {
      const rows = await allPages(async (offset, limit) => {
        const page = await service('PlaylistAPI').getContents(args.uri, { offset, limit });
        return { rows: page.items || [], total: page.totalLength || 0 };
      }, 100, 10000);
      return rows.map(item => track(item)).filter(Boolean);
    },

    albumTracks: async args => {
      let album = null;
      const rows = await allPages(async (offset, limit) => {
        const data = await query('getAlbum', { uri: args.uri, locale: '', offset, limit });
        const union = data.albumUnion || {};
        if (!album) album = { name: union.name || '', image: largestImage(union.coverArt && union.coverArt.sources) };
        const tracks = union.tracksV2 || union.tracks || {};
        return { rows: (tracks.items || []).map(row => row.track), total: tracks.totalCount || 0 };
      }, 50, 1000);
      return rows.map(item => track(item, album)).filter(Boolean);
    },

    artistTracks: async args => {
      const data = await query('queryArtistOverview', { uri: args.uri, locale: '', preReleaseV2: false });
      const union = data.artistUnion || {};
      const top = (union.discography && union.discography.topTracks && union.discography.topTracks.items) || [];
      return top.map(row => track(row.track)).filter(Boolean);
    },

    // Plays `uris` in First Row's order, from `index`. The list goes to the page as its own
    // context so Spotify plays on through it, and through nothing else.
    play: async args => {
      const uris = args.uris || [];
      const index = Math.max(0, Math.min(uris.length - 1, args.index || 0));
      const contextUri = args.contextUri || uris[index];
      const context = {
        uri: contextUri,
        url: 'context://' + contextUri + '?firstrow=' + Date.now(),
        pages: [{ items: uris.map(uri => ({ uri })) }],
      };
      await service('PlayerAPI').play(context, {}, { skipTo: { index, uri: uris[index] } });
      return true;
    },
    pause: () => service('PlayerAPI').pause(),
    resume: () => service('PlayerAPI').resume(),
    seek: args => service('PlayerAPI').seekTo(Math.max(0, Math.round(args.ms || 0))),
    state: () => playerState(),
  };

  const call = async (id, name, args) => {
    try {
      if (!commands[name]) throw new Error('First Row has no Spotify command ' + name);
      const value = await commands[name](args || {});
      send({ type: 'result', id, ok: true, value: value === undefined ? null : value });
    } catch (error) {
      send({ type: 'result', id, ok: false, error: String((error && error.message) || error) });
    }
  };

  let lastState = '';
  const pushState = () => {
    let state = null;
    try { state = playerState(); } catch (e) { return; }
    const { now, ...comparable } = state || {};
    const text = JSON.stringify(comparable);
    if (text === lastState) return;
    lastState = text;
    send({ type: 'state', state });
  };

  const announce = async () => {
    if (!platform) return;
    let account = { signedIn: false, name: '', username: '' };
    try { account = await commands.account(); } catch (e) {}
    send({ type: 'ready', signedIn: account.signedIn, name: account.name, username: account.username });
    lastState = '';
    pushState();
  };

  // On Linux and Windows the page runs in a browser of its own, which carries on if First Row
  // quits or crashes. First Row checks in every few seconds; when it stops, so does the music.
  let lastAlive = 0;
  const alive = () => { lastAlive = Date.now(); };
  setInterval(() => {
    if (!lastAlive || Date.now() - lastAlive < 20000) return;
    lastAlive = 0;
    try { service('PlayerAPI').pause(); } catch (e) {}
  }, 5000);

  window.firstRowSpotify = { call, announce, alive };

  const started = Date.now();
  const connect = () => {
    const found = findPlatform();
    if (!found) {
      if (Date.now() - started > 60000) send({ type: 'failed', error: 'Spotify did not finish loading' });
      else setTimeout(connect, 250);
      return;
    }
    platform = found;
    for (const key of platform.getRegistry()._map.keys()) {
      if (key && key.description) symbols[key.description] = key;
    }
    try {
      const events = service('PlayerAPI').getEvents();
      events.addListener('update', pushState);
      events.addListener('error', event => send({ type: 'playerError', error: String((event && (event.data && (event.data.code || event.data.message) || event.message)) || 'error') }));
    } catch (e) {}
    // A page that isn't drawn gains nothing from its home page's thousands of rows and images.
    try {
      const history = platform.getHistory && platform.getHistory();
      if (history && location.pathname !== '/preferences') history.replace('/preferences');
    } catch (e) {}
    announce();
  };
  connect();
})();
"""#
