# Pooled pages: the JS contract

With `pagesPooledIn(windowId)` true, `TabViewPool` owns every page view in the window and RN mounts none
(architecture.md › Page views: static ownership). Everything the app did through a mounted `EngineWebView` still has
to happen. This is who does each part. Native side: port-omnibox. JS side: port-shell.

## Gate

One check, `pagesPooledIn(windowId)` in `apps/browser/src/lib/pagesPool.ts`: the shell, pane roots,
`ARDIA_NATIVE_PAGES_POOL=1` and `SolaraTabPool.available()`. ContentCard, Peek and the JS pool session read it, so a
build where the pool can't serve pages keeps RN's. `windowPagesPoolActive()` is the switch alone: native split chrome
keys off it, and it stays on when `ARDIA_TAB_POOL=0` turns the pool off.

## Page events

The pool is each page view's delegate and sends every event the `ArdiaCEF` and `ArdiaWebKit` view managers send,
as one feed: `SolaraTabPool` event `onPageEvent` with `{ tabId, name, payload }`.

- `name` is the view manager's prop name (`onNavigationChange`, `onProgress`, … `onPagePress`, `onReady`), every one.
- `payload` is the same dictionary the view manager puts in `nativeEvent`: same keys, engine URLs (JS converts them).
- Per tab, events arrive in the order the page sent them. The feed is one ordered stream, not a task per event.
- Two more names that only the pool sends: `onPageCreated { engine, seq, url }` when it makes a view for the tab (the
  navigation `seq` it loaded on create, or -1 for an adopted or transferred page) and `onPageGone {}` when the view is
  destroyed or leaves the pool (park, crossing to Little Solara). A second `onPageCreated` for a tab means a new view (an engine
  switch, a re-create after a crash): JS starts the tab's session over, so the pool never sends one for a view it
  already reported. A transferred page with `seq` -1 counts whatever navigation the store holds as already loaded.

JS turns `{ name, payload }` into the prop's arguments with `@ardia/ardiacore`'s `unwrapPageEvent`, the same table the
RN component uses, and calls the tab's handler from `pageEvents.ts`, the same function `EngineWebView` calls.

## The handle

The ~40 callers of `webviews.get(tabId)` keep working: JS registers a pooled `WebViewHandle` in `webviews` on
`onPageCreated` and deletes it on `onPageGone`.

- `SolaraTabPool.pageCall(tabId, method, args)` is the one native entry: `method` is the view manager's AsyncFunction
  name (`goBack`, `loadUrl`, `find`, `focus`, …) and `args` its arguments, as the RN view's native handle passes them
  (engine URLs, `loadUrl(url, userInitiated)`). It resolves to what that AsyncFunction resolves to. Both kinds of page
  run one Swift dispatcher.
- `@ardia/ardiacore` builds both handles from one typed function over that native handle (`pooledWebViewHandle`), so
  URL conversion, `evaluate`'s JSON and fallbacks match, and TypeScript checks every method and argument.
- A call for a tab the pool has no view for rejects with code `ERR_NO_PAGE`; the handle returns the same fallback the
  RN handle returns for a missing view.
- `nativeTag()` is null for a pooled page. Its one caller, the focus-move claim in `focusHandoff.ts`, claims a pooled
  page by tab id instead (`SolaraTabPool.claimFocusPage(generation, tabId)`), which resolves the tab's pooled view and
  hands it to the shell's focus-move claim.
- WebKit tabs get a `WebKitTab` view through the same adapter, with the same events and handle.
- `pageCall(tabId, "focus", [])` makes the page view first responder in its window. Peek's open, Open as Tab and Split use it.

## What a mounted EngineWebView did besides events

| Logic | Owner when pooled |
|---|---|
| Navigation: `loadUrl` on a new `navigation.seq`, skipping the seq loaded on create, a started navigation (`takeStartedNavigation`) and an adopted URL | JS pool session, per tab, same code as `EngineWebView` (`pageSession.ts`) |
| `noteIssued`, `persistEngine`, `noteReady`, `setBrowserId`, `noteChromeTab`, muted on ready | shared handlers (`onReady`, `onPageCreated`) |
| `noteGone`, progress to 0 | `onPageGone` |
| Initial page: `url`, `adoptId`, `profile`, `engine`, `transferKey` | pool, from the store (`TabViewWanted`) |
| `visible`, `warm`, `neighbour` | pool, from where it places the view |
| `temporary` / `temporarySource` (Peek's source) | pool, from `state.peeks` |
| `pageColor`, `contentsBackgroundColor`, `autoPictureInPicture`, `shownUrl` | JS computes them as today and pushes them: `SolaraTabPool.setPageProps(tabId, { … })`, only on change |
| Discard and resume | shared `onDiscarded` handler sets the session's pending URL; resume goes through the navigation path above |
| `handOff` / `takeHandOff`, `adoptId` transfers, pin handoffs, peek to tab | not in pooled mode: the pool moves its own view between slots and windows. Crossing to Little Solara is the park path |
| New Tab prewarm (`usePrewarm`) | off in pooled windows |
| A page's `onWindowClose(withWindow)`: `withWindow` is true when Chrome started the window's close (an extension's `chrome.windows.remove`) | shared handler: `closeTabs([tabId], { lastClosesWindow: true, windowClosedByChrome: withWindow })` |
| Split-pane activation on a click (`TabPane` `onTouchStart`) | shared `onPageFocus` and `onPagePress` handlers (`activateSplitPane`). A left press on a page no longer reaches RN's touch handler, so `onPagePress` is the only click signal |

## Checks

`pool-e2e-test.mjs`, with the pool on: a handle call reaches the page (find, zoom, back, `evaluate`), one event of
each kind reaches the store (title and favicon, progress, a notification click focuses its tab), a click in the
unfocused split pane focuses it, and a peek opens and promotes.
