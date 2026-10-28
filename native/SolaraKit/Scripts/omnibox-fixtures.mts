const HELP = `Records packages/core's answers for SolaraOmnibox's differential tests.

  node native/SolaraKit/Scripts/omnibox-fixtures.mts [--out <dir>] [--runs <n>] [--big <n>]

Every case is generated from a fixed seed, run through the TypeScript code in packages/core/src, and written
as JSON next to its expected output. The Swift tests replay the inputs and must give the same outputs.
--out defaults to Tests/SolaraOmniboxTests/Fixtures; --runs and --big set how many keystroke-sequence runs
(profiles of up to 151 rows, and of 1500 rows) suggest.json holds. The committed set uses the defaults;
a larger set (--runs 500 --big 12, the size of suggest.property.test.ts) can be written elsewhere and passed
to the tests with SOLARA_OMNIBOX_FIXTURES=<dir>.`;

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { domainToASCII } from "node:url";
import * as appUrls from "../../../packages/core/src/appUrls.ts";
import * as bangs from "../../../packages/core/src/bangs.ts";
import { BANG_LIST, BANG_LIST_UNICODE } from "../../../packages/core/src/bangList.ts";
import { calculate, evaluate } from "../../../packages/core/src/calculator.ts";
import { cleanUrl, markdownLink } from "../../../packages/core/src/cleanUrl.ts";
import * as engines from "../../../packages/core/src/engines.ts";
import { extensionSuggestions } from "../../../packages/core/src/extensionRows.ts";
import { fuzzyScore, matchActions } from "../../../packages/core/src/fuzzy.ts";
import { displayHost, hostSpoofReason, punycodeEncode } from "../../../packages/core/src/idn.ts";
import * as omnibox from "../../../packages/core/src/omnibox.ts";
import { recentTabSuggestions } from "../../../packages/core/src/openTabs.ts";
import { matchQuickCreate } from "../../../packages/core/src/quickCreate.ts";
import * as siteSearch from "../../../packages/core/src/siteSearch.ts";
import { buildSuggestions, displayUrl, prepareSuggestions, type SuggestionSource, type SuggestOptions } from "../../../packages/core/src/suggest.ts";
import * as reference from "../../../packages/core/src/suggest.reference.ts";
import { chooseTextFragment, withTextFragment } from "../../../packages/core/src/textFragment.ts";

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const flag = (name: string, fallback: string) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1]! : fallback);
const here = dirname(fileURLToPath(import.meta.url));
const out = flag("out", join(here, "../Tests/SolaraOmniboxTests/Fixtures"));
const RUNS = Number(flag("runs", "70"));
const BIG = Number(flag("big", "3"));
mkdirSync(out, { recursive: true });

function rng(seed: number) {
  let s = seed >>> 0;
  const next = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
  const int = (n: number) => Math.floor(next() * n);
  const pick = <T,>(list: readonly T[]): T => list[int(list.length)]!;
  return { next, int, pick };
}
type Rng = ReturnType<typeof rng>;

const num = (x: number) => (Number.isFinite(x) ? (Object.is(x, -0) ? "-0" : x) : String(x));
const bits = (x: number) => {
  const b = Buffer.alloc(8);
  b.writeDoubleBE(x);
  return b.toString("hex");
};
const write = (name: string, data: unknown) => {
  const text = JSON.stringify(data);
  writeFileSync(join(out, name), text);
  console.log(`${name}: ${(text.length / 1024).toFixed(0)} KB`);
};
const wellFormed = (s: string) => s.isWellFormed();

function lowerCases() {
  const changes: [number, string][] = [];
  for (let cp = 0; cp <= 0x10ffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;
    const c = String.fromCodePoint(cp);
    const lower = c.toLowerCase();
    if (lower !== c) changes.push([cp, lower]);
  }
  const samples = ["ΟΔΟΣ", "ΟΔΟΣ ΟΔΟΣ.", "Σ", "ΑΣ", "ΑΣ\u0301", "ΑΣ\u0301Β", "Α'Σ", "Σ'Α", "İSTANBUL", "ǅ", "ẞ", "ΑΣ1", "aΣ", "ꭰ", "Ꭰ", "AΣ.B", "AΣ\u00adB", "\u{10400}Σ", "ﬀ", "İi̇"];
  return { changes, samples: samples.map((s) => [s, s.toLowerCase(), s.toUpperCase()]) };
}

function numberCases() {
  const r = rng(11);
  const values: number[] = [0, -0, 1, -1, 0.1, 0.5, 1.5, 2.5, 1e21, 1e-7, 1e-6, 0.000001, 123456789012345680000, 1e20, 9.999999999999999e20, 5e-324, Number.MAX_VALUE, -Number.MAX_VALUE, Number.MIN_VALUE, NaN, Infinity, -Infinity, 1000000000000.5, 100000000000.5, 0.30000000000000004, 1 / 3, 2 / 3, Math.PI, Math.E, 123.456, 1e-9, 9.99999999999e-10, 999999999999.5, 99999999999.95, 1.0000000000005, 4.35, 1.005, 0.000123456789012345, 6.02214076e23, 299792458, 2 ** 53, 2 ** 53 + 2, 2 ** 70, 1e100];
  const buf = Buffer.alloc(8);
  for (let i = 0; i < 3000; i++) {
    for (let k = 0; k < 8; k++) buf[k] = r.int(256);
    values.push(buf.readDoubleBE(0));
  }
  for (let i = 0; i < 3000; i++) values.push((r.int(2) ? -1 : 1) * r.int(10 ** r.int(16)) / 10 ** r.int(20));
  for (let i = 0; i < 500; i++) values.push(Number((r.int(1e6) + 0.5).toString() + "e" + (r.int(40) - 20)));
  for (let i = 0; i < 300; i++) values.push(Math.round(r.next() * 1e12) + 0.5);
  return values.map((x) => ({ bits: bits(x), string: String(x), p12: x.toPrecision(12), p9: x.toPrecision(9), exp: x.toExponential() }));
}

function log2Cases() {
  const r = rng(12);
  const visits: number[] = [];
  for (let n = 0; n < 5000; n++) visits.push(n);
  for (let i = 0; i < 2000; i++) visits.push(r.int(2 ** 31));
  for (let i = 0; i < 1000; i++) visits.push(r.next() * 1000);
  return visits.map((v) => [bits(v), bits(Math.log2(1 + v) * 8)]);
}

const URL_PIECES = [
  "", "http://", "https://", "HTTPS://", "Http://", "ftp://", "chrome://", "ardia://", "solara://", "SOLARA://", "about:", "About:", "view-source:", "file://", "/", "//", "www.", "WWW.",
  "xn--", "xn--bcher-kva", "xn--80ak6aa92e", "xn--nxasmq6b", "localhost", "LocalHost", "127.0.0.1", "192.168.1.1", "10.0.0", "[::1]", "[2001:db8::1]", "[zz]", "example", "foo", "my-site",
  "münchen", "яндекс", "例え", "😀", "İ", "Σ", "ß", ".", "..", ".com", ".org", ".co.uk", ".zzzz", ".photography", ".рф", ".中国", ".local", ".test", ".js", ".html", ".new", ".dev", ":", ":8080",
  ":99999", ":abc", "?", "?q=1", "?utm_source=x&a=b", "#", "#top", "#a\nb", " ", "  ", "\t", "\u00a0", "\u2028", "\n", "\r\n", "@", "user:pw@", "\\", "%20", "%41", "%E2%82%AC", "%ZZ", "%", "!",
  "!gh", "mailto:", "tel:", "data:", "javascript:", "1", "10:30", "3.14", "e.g.", "c++", "a", "B", "version", "settings/sync", "settings", "newtab", "history", "bookmarks", "downloads", "flags",
  "-", "_", "~", "'", "(", ")", "*", "é", "e\u0301", "ǅ", "ﬀ", "Ⅻ", "ｙｏｕｔｕｂｅ", "youtube.com", "youtu.be", "music.youtube.com", "x.com", "amazon.co.uk", "open.spotify.com", "si=abc", "&",
  "=", "fbclid=1", "ref_=x", "pd_rd_w=1", "UTM_Medium=y", "+", "%2B", "&&", "about:blank", "about:srcdoc", "about:flags", "chrome://version/", "ardia://history/?q=a", "solara://settings/sync",
  "view-source:chrome://version", "| ", " | ", " - ", " — ", " · ", " / ", "Home", "GitHub",
];

function urlInput(r: Rng): string {
  let s = "";
  const n = 1 + r.int(6);
  for (let i = 0; i < n; i++) s += r.pick(URL_PIECES);
  return s;
}

const URL_SAMPLES = [
  "apple.com", "localhost:3000", "192.168.1.1/admin", "https://x.com/home", "about:blank", "how to cook rice", "react", "   ", "example.com:8080/x", "[::1]:8080", "printer.local",
  "myapp.localhost:5173", "HTTPS://Example.com/Path", "file:///Users/me/a.html", "/Users/me/My File.html", "mailto:hi@example.com", "xn--bcher-kva.example", "bücher.de", "en.wikipedia.org/wiki/Cat",
  "github.io", "example.co.uk", "index.html", "node.js", "hi@example.com", "what is apple.com", "note: buy milk", "c++", "javascript:alert(1)", "1.5", "e.g.", "docs.internal/setup",
  "site.photography/about", "myserver:8080", "devbox:3000/api/health?x=1", "foo.zzzz:8080", "10:30", "3:2", "8080", "12:30pm", "ratio 3:2", "note: 5", "a:b", "std::vector", "münchen.de", "Яндекс.рф",
  "яндекс.рф/search?text=x", "例え.jp", "bücher.example/x/", "xn--bcher-kva.de", "café.fr:8443", "café", "münchen.zzzz", "naïve bayes.com", "foo.zzzz", "foo.zzzz/x", "foo.zzzz?x=1", "foo.zzzz#top",
  "foo.zzzz/", "foo.zzzz/x/", "foo.zzzz/x?y=1", "foo.zzzz/x#y", "x.y/", "https://foo.zzzz/x", "http://foo", "foo/bar", "foo/", "wiki/Main?x=1", "and/or", "docs.new", "report.zip", "shop.bike",
  "hello.world", "a.xn--p1ai", "b.中国", "c.рф", "a.b", "v1.2.3", "file.txt", "README.md.bak", "ardia://version", "chrome://version/", "chrome://settings/languages", "ardia://history/?q=a",
  "chrome://gpu/", "chrome://flags/", "solara://version", "SOLARA://version", "view-source:chrome://version", "about:flags", "ardia://settings/sync", "solara://newtab", "solara://bookmarks",
  "https://example.com/post?utm_source=newsletter&utm_medium=email&utm_campaign=fall", "https://example.com/?fbclid=IwAR0abc", "https://shop.example/item?id=42&gclid=Cj0KCQ&color=red",
  "https://news.example/a?mc_eid=123&mc_cid=456&page=2", "https://x.example/?_hsenc=p2A&_hsmi=1&msclkid=9", "https://example.com/?UTM_Source=caps", "https://example.com/a?q=a%20b&utm_source=x#section-2",
  "https://example.com/a?utm_source=x#frag?utm_medium=y", "https://example.com/search?q=utm_source", "https://example.com/?b=2&a=1", "https://example.com/path", "https://user:pw@example.com:8443/p?utm_term=x&k",
  "https://www.youtube.com/watch?v=1&si=abc&feature=share", "https://youtu.be/x?si=1", "https://open.spotify.com/track/1?si=2&nd=1", "https://x.com/a/status/1?s=20&t=abc", "https://www.amazon.co.uk/dp/1?ref_=x&pd_rd_w=y&keep=1",
  "https://ＹＯＵＴＵＢＥ.com/?si=1", "https://xn--zz.com/?utm_source=1", "https://exa mple.com/?utm_source=1", "https://example.com:99999/?utm_source=1", "https://[::1]/?utm_source=1", "https://[zz]/?utm_source=1",
  "https://0x7f.1/?utm_source=1", "https://1.2.3.4.5/?utm_source=1", "https://256.1/?utm_source=1", "https:example.com/?utm_source=1", "https:\\\\example.com/?utm_source=1", "https://@example.com/?utm_source=1",
  "https://a@/?utm_source=1", "ftp://example.com/?utm_source=1", "HTTPS://YouTube.com/?SI=1", "https://m.youtube.com/?si=1&x=%ZZ", "https://example.com/?%75tm_source=1", "https://example.com/?utm+source=1",
  "https://example.com/?a=1&&b=2", "https://example.com/?&", "https://example.com/?", "https://example.com/#?utm_source=1", " https://example.com/?utm_source=1 ", "https://example.com/?utm_source=1#a\nb",
  "javascript://x%0Aalert(document.domain)", "JAVASCRIPT://x", "view-source:javascript:alert(1)", " javascript:javascript:alert(1)", "\u0001javascript://x", "java\nscript:alert(1)",
  "javascript:", "javascript:example.com", "\u007fJavaScript: javascript:x", "https://accounts.google.com@evil.com/", "https://a@b@evil.com:8443/x", "http://localhost:3000/", "https://example.com:443/a",
  "http://example.com:80/", "ws://example.com:81/", "ftp://example.com:21/", "https://fidélity.com/", "https://schwáb.com/",
];

const TITLES = ["", "About Version", "History", "Experiments", "(1) Home / X", "GitHub - facebook/react: The library", "Inbox - me@gmail.com - Gmail", "a | b | a", "x.com / Home", "React – A JavaScript library", "Foo — Bar · Baz", "One - Two -Three", " - ", "Title\u00a0-\u00a0Sub", "İstanbul - istanbul"];

function urlCases() {
  const r = rng(21);
  const inputs = [...URL_SAMPLES];
  for (let i = 0; i < 1500; i++) inputs.push(urlInput(r));
  const attempt = (f: () => unknown) => {
    try {
      return f();
    } catch (error) {
      return { throws: String(error) };
    }
  };
  const pass = () =>
    inputs.filter(wellFormed).map((input, i) => {
      const title = TITLES[i % TITLES.length]!;
      return {
        input,
        title,
        fixupUrl: attempt(() => omnibox.fixupUrl(input)),
        resolveInput: attempt(() => omnibox.resolveInput(input)),
        resolveDuck: attempt(() => omnibox.resolveInput(input, "https://duckduckgo.com/?q=%s")),
        classifyPaste: attempt(() => omnibox.classifyPaste(input)),
        sanitizePaste: attempt(() => omnibox.sanitizePaste(input)),
        hostOf: attempt(() => omnibox.hostOf(input)),
        urlForDisplay: attempt(() => omnibox.urlForDisplay(input)),
        displayUrl: attempt(() => displayUrl(input)),
        breadcrumb: attempt(() => omnibox.breadcrumb(input, title)),
        cleanUrl: attempt(() => cleanUrl(input)),
        markdownLink: attempt(() => markdownLink(title, input)),
        appUrlOrigin: attempt(() => appUrls.appUrlOrigin(input)),
        toAppUrl: attempt(() => appUrls.toAppUrl(input)),
        toEngineUrl: attempt(() => appUrls.toEngineUrl(input)),
        appUrlRoute: attempt(() => appUrls.appUrlRoute(input)),
        isAppScheme: attempt(() => appUrls.isAppScheme(input)),
        searchUrlFor: attempt(() => omnibox.searchUrlFor("https://e.example/?q=%s&again=%s", input)),
      };
    });
  appUrls.setAppScheme(null);
  const ardia = pass();
  appUrls.setAppScheme("Solara");
  const solara = pass();
  appUrls.setAppScheme(null);
  const products = ["Solara", "My Browser", "Chrome", "HTTP", "42", "", "  Solara  ", "ŞOLARA", "\u212aelvin", "a+b.c-d", "view-source", "Ardia", "x y z", "Javascript", "chrome-extension"];
  return {
    ardia,
    solara,
    appSchemeFor: [...products.map((p) => [p, appUrls.appSchemeFor(p)]), [null, appUrls.appSchemeFor(null)]],
  };
}

const SCRIPT_CHARS = [
  "abcdefghijklmnopqrstuvwxyz0123456789-",
  "аеорсхуіјӏԁһѕԝԛпгзикмнтвбьъЬҽѵѡ",
  "αβγδεικνορστυχωϲ",
  "աբգդեզէլհյնոսւօցքՙ",
  "אבגדהוזחטיכלמןסעפצקרשתם",
  "ابتثجحخدذرزسشصضطظعغفقكلمنهوي\u064b\u0652\u0670٠١٢٣",
  "अआइईउऊएकखगघचछजझटठडढतथदधनपफबभमयरलवशसह०१२३२",
  "กขคงจฉชซญดตถทธนบปผพฟภมยรลวศษสหอฮเแ๐",
  "ກຂຄງຈຊຍດຕຖທນບປຜຝພຟມຢຣລວສຫອຮ໐",
  "一丁七万三上下不与专中丶乀乁丿",
  "あいうえおかきくけこへべぺ",
  "アイウエオカキクケコヘベペノンソゾーヽヾ・",
  "가나다라마바사아자차카타파하",
  "აბგდევზთიკლმნოპჟრსტუფქღყშჩცძწჭხჯჰჽ",
  "ሀሁሃሠሡሰሱሲቀቁበቡነኑኒከኮዐዑዕዖፀፁፐ",
  "ㄅㄆㄇㄈㄧ",
  "ßςς\u200c\u200d·əþðı\u0300\u0301\u0307\u0339\u0335\u05b4",
  "ឧកខគ",
  "ථකග",
  "θ२২੨૨೩೭Շзҙӡउওਤ੩૩౩ဒვპ੫丩ㄐճ৪੪୫૭୨౨",
  "éèêëñöüçåøłđħŧœæ",
  "😀🎉",
];

function idnCases() {
  const r = rng(31);
  const label = () => {
    const pool = r.pick(SCRIPT_CHARS);
    const mixed = r.int(4) === 0 ? r.pick(SCRIPT_CHARS) : pool;
    const chars = [...pool, ...(mixed === pool ? [] : [...mixed])];
    return Array.from({ length: 1 + r.int(6) }, () => r.pick(chars)).join("");
  };
  const tlds = ["com", "ru", "рф", "gr", "jp", "am", "il", "ge", "th", "la", "lk", "kh", "et", "cat", "is", "az", "org", "xn--p1ai", "中国", "co.uk", ""];
  const hosts: string[] = [];
  const unicode: string[] = [];
  for (let i = 0; i < 8000; i++) {
    const parts = Array.from({ length: 1 + r.int(2) }, label);
    const tld = r.pick(tlds);
    const host = parts.join(".") + (tld ? `.${tld}` : "");
    unicode.push(parts[0]!);
    const ascii = domainToASCII(host);
    if (ascii) hosts.push(ascii, r.int(5) === 0 ? `www.${ascii}` : ascii.toUpperCase());
  }
  const lookalikes = ["аpple.com", "gοogle.net", "пα.com", "аррӏе.com", "аррӏе.ru", "аррӏе.рф", "ικα.com", "ικα.gr", "ოყ.com", "ทน.com", "օս.com", "aノb.com", "abcン.com", "カヘカ.jp", "カへカ.jp", "ーabc.jp", "oհ.com", "gооgle.com", "paypaӏ.com", "раураl.com", "xn--80ak6aa92e.com", "faceb00k.com", "rnicrosoft.com", "аmаzоn.com", "bücher.de", "münchen.de", "例え.jp"];
  for (const h of lookalikes) {
    const ascii = domainToASCII(h);
    if (ascii) hosts.push(ascii);
  }
  hosts.push("xn--" + punycodeEncode("ai\u0307b") + ".com", "xn--zzzzz.com", "xn--.com", "xn--a.com", "xn--ls8h.la", "XN--BCHER-KVA.de", "a.xn--p1ai", "xn--bcher-kva.xn--p1ai", "example.com", "", ".", "xn--bcher-kva.", "xn--bcher-kva..de");
  for (let i = 0; i < 500; i++) hosts.push("xn--" + Array.from({ length: 1 + r.int(10) }, () => r.pick([..."abcdefghijklmnopqrstuvwxyz0123456789-"])).join("") + "." + r.pick(tlds));
  return {
    hosts: hosts.map((host) => [host, displayHost(host), hostSpoofReason(host)]),
    punycode: unicode.filter(wellFormed).map((u) => [u, punycodeEncode(u)]),
  };
}

const CALC_PIECES = [
  "1", "2", "3", "10", "2.5", "1e3", "1E-2", "1,234", "1,234,567", "12,34", ".5", "5.", "0", "170", "171", "1e400", "007", "π", "Π", "ϖ", "τ", "Τ", "pi", "PI", "e", "E", "tau", "x", "X", "mod", "of",
  "deg", "degrees", "sqrt(", "SIN(", "cos(", "tan(", "log(", "log2(", "log10(", "ln(", "exp(", "abs(", "floor(", "ceil(", "round(", "min(", "max(", "pow(", "cbrt(", "asin(", "atanh(", "constructor", "foo",
  "(", ")", ",", "+", "-", "*", "/", "^", "**", "%", "!", "×", "·", "÷", "−", "–", "°", " ", "  ", "\u00a0", "=", "?", "= ?", "$", "km", "mi", "kg", "lb", "°c", "°f", "c", "f", "k", "kelvin", "to",
  "in", "into", "as", "->", "→", "fl oz", "fl  oz", "m/s", "km/h", "mph", "GB", "MiB", "bytes", "B", "b", "days", "hours", "min", "cups", "tbsp", "2024-01-05", "1.2.3", "\u212a", "ſ",
];

const CALC_SAMPLES = [
  "2+2", "2 + 2 =", "= 3*4", "10/4", "2^10", "2**10", "5!", "50%", "10 % 3", "10 mod 3", "20% of 50", "3x4", "2π", "2pi", "sqrt(16)", "sin(90°)", "sin(90 deg)", "log(100)", "log(8, 2)", "ln(e)", "min(3, 1, 2)",
  "max(1, NaN)", "1,234 + 1", "1,234,567 * 2", "pow(2, 10)", "pow(2)", "round(2.5)", "round(-2.5)", "round(0.49999999999999994)", "floor(-0.5)", "abs(-3)", "1/3", "2/3", "0.1+0.2", "1e21*10", "1e-10 * 2",
  "170!", "171!", "(1+2)*3", "-(2)", "--2", "+-+2", "2(3)", "(2)(3)", "2 pi", "pi e", "5 km to mi", "5 km in miles", "100 °f to °c", "100 f to c", "0 c to k", "300 kelvin to fahrenheit", "1 fl oz to ml",
  "1 fl  oz to ml", "60 mph to km/h", "1 GB to MiB", "1 B to bits", "3 days to hours", "1 cup to tbsp", "2+2 km to mi", "5 kg to mi", "2024-01-05", "1.2.3", "1.2", "12", "e", "pi", "π", "x", "2024",
  "constructor(5)+1", "2 * constructor", "1 ΚΜ to mi", "2Π", "2ϖ", "2Τ", "5 \u212a to c", "5 ſ to ms", "3 ** 2 ** 2", "2^-1", "-2^2", "2^3!", "4!!", "3!%", "50%%", "10 % (3)", "1e3e3", "0x10", "1..2",
  "1 + ", "", "   ", "=", "= ?", "2+2=?", "2+2 = ?", "2 +2", "sqrt 4", "sqrt(4", "sqrt(4))", "log(0)", "sqrt(-1)", "1/0", "-1/0", "0/0", "tan(pi/2)", "exp(710)", "exp(-746)", "1e-7*1", "123456789*987654321",
  "0.1*3", "100000000000000000000+1", "9007199254740993*1", "1.0000000000005*1", "999999999999.5*1", "atan(1)*4", "cbrt(27)", "cosh(1)", "asin(2)", "2 x 3", "2 X 3", "2 of 3", "2 mod 0",
];

function calcCases() {
  const r = rng(41);
  const inputs = [...CALC_SAMPLES];
  for (let i = 0; i < 12000; i++) {
    let s = "";
    const n = 1 + r.int(7);
    for (let k = 0; k < n; k++) s += r.pick(CALC_PIECES);
    inputs.push(s);
  }
  return inputs.map((input) => {
    const c = calculate(input);
    const ev = evaluate(input);
    return { input, calc: c && { expression: c.expression, value: num(c.value), display: c.display }, evaluate: ev === null ? null : num(ev) };
  });
}

const filler = Array.from({ length: 1000 }, (_, i) => ({ s: `Site ${i}`, ts: [`site${i}`], u: `https://site${i}.example/?q={searchTerms}` }));

function heliumFile(entries: unknown[]): string {
  const body = JSON.stringify([...entries, ...filler], null, 1).replace(/"\n(\s*)([\]}])/g, '",\n$1$2');
  return `// Generated at 2026-10-14T11:11:02.825Z\n// MIT License\n//\n\n${body}\n`;
}

const HELIUM = heliumFile([
  { s: "GitHub", ts: ["gh", "git", "github"], u: "https://github.com/search?q={searchTerms}" },
  { s: "GitHub Repo", ts: ["ghr"], f: 1, u: "https://github.com/{searchTerms}" },
  { s: "Wikipedia", ts: ["w", "wiki"], u: "https://wikipedia.org/w/index.php?search={searchTerms}" },
  { s: "YouTube", ts: ["yt", "ют"], u: "https://www.youtube.com/results?search_query={searchTerms}" },
  { s: "Zig", ts: ["zig"], u: "https://ziglang.org/documentation/master/std/#?{searchTerms}" },
  { s: "Gmail", ts: ["gmail"], u: "https://mail.google.com/mail/u/0/#search/{searchTerms}" },
  { s: "T3 Chat", ts: ["t3"], u: "https://www.t3.chat/new?q={searchTerms}", sc: "ai" },
  { s: "Microsoft Copilot", ts: ["copilot"], u: "https://copilot.microsoft.com/?q={searchTerms}" },
  { s: "DuckDuckGo AI Chat", ts: ["ddg-chat"], u: "https://duckduckgo.com/?q={searchTerms}&ia=chat&bang=true" },
  { s: "Not a web page", ts: ["ftp"], u: "ftp://example.com/{searchTerms}" },
  { s: "Read the Docs", ts: ["rtfd"], u: "https://{searchTerms}.rtfd.io/" },
  { s: "hypestat", ts: ["hypestat"], u: "https://www.{searchTerms}.hypestat.com/" },
  { s: "No slash", ts: ["noslash"], u: "https://example.com{searchTerms}" },
  { s: "Port", ts: ["port"], u: "https://example.com:{searchTerms}/" },
  { s: "User", ts: ["user"], u: "https://{searchTerms}@example.com/" },
  { s: "Taken", ts: ["gh"], u: "https://taken.example/?q={searchTerms}" },
  { s: "  Spaced\tName  ", ts: [" SP ", "s p", "x!", 5, "", "Sp2"], u: "HTTPS://spaced.example/{searchTerms}?a={searchTerms}" },
  { s: "Bad", ts: "nope", u: "https://bad.example/{searchTerms}" },
  { s: 7, ts: ["seven"], u: "https://seven.example/{searchTerms}" },
  { s: "Stored", ts: ["stored"], u: "https://stored.example/{s}/{searchTerms}" },
  ["not", "an", "object"],
  null,
  { s: "Http", ts: ["plainhttp"], u: "http://plain.example/?q={searchTerms}" },
]);

const BANG_WORDS = ["!gh", "!GH", "!w", "!Wiki", "!yt", "!ют", "!nope", "!", "!!", "!ghr", "!gmail", "!zig", "!rtfd", "!hypestat", "!noslash", "!copilot", "!t3", "!sp", "!SP2", "!plainhttp", "react", "hooks", "a+b", "&", "c/d", "#x", "100%", "日本", "語", "it's", "(ok)*!~", "std.mem", "facebook/react", "a b?c#d%e", "from:me", "é", "?", "?react", "hello!", "hi!gh", "wow", "evil.example/", "@evil.example", "evil.example#", "evil.example\\", "//evil.example", "evil.example%2F", "\t", "\u00a0", "  "];

function bangCases() {
  const r = rng(51);
  const slim = bangs.slimBangs(HELIUM)!;
  const table = bangs.bangTable(slim);
  const finds: unknown[] = [];
  for (let i = 0; i < 4000; i++) {
    const n = 1 + r.int(4);
    const words = Array.from({ length: n }, () => r.pick(BANG_WORDS));
    const text = (r.int(6) === 0 ? "  " : "") + words.join(r.pick([" ", "  ", "\t"])) + (r.int(6) === 0 ? " " : "");
    finds.push([text, bangs.findBang(text, table)]);
  }
  const terms: unknown[] = [];
  for (let i = 0; i < 2000; i++) {
    const text = Array.from({ length: 1 + r.int(4) }, () => r.pick([...BANG_WORDS, "\u0000", "\u007f", "\u{1F600}", "ß", "~", "`", "^", "|", "{", "}", "[", "]", "<", ">", '"', ":"])).join(r.pick([" ", ""]));
    terms.push([text, bangs.escapeSearchTerms(text, true), bangs.escapeSearchTerms(text, false), bangs.fillBangTemplate("https://a.example/{searchTerms}/x?q={searchTerms}", text), bangs.fillBangTemplate("https://a.example/p/{searchTerms}", text)]);
  }
  const sites: unknown[] = [];
  const urls = ["https://github.com/search?q=a", "https://GitHub.com/a", "https://github.com\\@evil.example/", "https://github.com@evil.example/", "https://evil.example/github.com/", "http://github.com/a", "https://github.com:444/a", "https://github.com.evil.example/", "https://github.com/a\tb", "https://github.com/a\nb", "HTTPS://GITHUB.COM/", "https://github.com", "github.com/a", "https://", "https://github.com/\u007f", "https://ГИТ.com/", "https://гит.com/x"];
  const templates = ["https://github.com/search?q={searchTerms}", "https://github.com/{searchTerms}", "https://x.example{searchTerms}", "https://гит.com/{searchTerms}", "nope", "https:///x"];
  for (const u of urls) for (const t of templates) sites.push([u, t, bangs.staysOnSite(u, t)]);
  const loose: unknown[] = [];
  const looseSamples = ['// head\n[\n {"u": "https://a//b", /* c */ "ts": ["x",],},\n // tail\n]\n', '["a\\\\", "b,]", "c\\"//"]', "[1,2,]", "[1,,2]", "{\"a\":1,}", "[/* x */]", "[// x\n]", "{\"a\": 1, \"a\": 2}", "{\"b\":1,\"2\":2,\"1\":3}", "[\"\\u00e9\", \"\\n\"]", "nope", "", "[1, 2 /* unterminated", "[\"a\" // c\n, \"b\"]", "  [ ]  ", "[1e400, -0, 0.5e-3]", "[\"/\", \"/*\", \"*/\"]", "[\"a\\\\\\\"b\"]", "[true,false,null]", "[01]", "[1.]", "[.5]", "{\"a\":[1,{\"b\":2,},],}", "[\t\n\r 1]", "[\u00a01]", "[,]", "{,}"];
  for (const text of looseSamples) {
    try {
      loose.push([text, true, bangs.parseLooseJson(text)]);
    } catch {
      loose.push([text, false, null]);
    }
  }
  const checked: unknown[] = [];
  const variants = [slim, `${slim}\nbad\tBroken\thttps://bad host/`, `${slim}\nbad\tBroken`, `${slim}\nbad\tBroken\tx.example/{s}\textra`, slim.split("\n").filter((l) => !l.startsWith("yt ")).join("\n"), slim.split("\n").slice(0, 900).join("\n"), `${slim}\na  b\tTwo\tx.example/{s}`, `${slim}\n a\tLead\tx.example/{s}`, `${slim}\na!\tBang\tx.example/{s}`, `${slim}\n\tNoTrigger\tx.example/{s}`, `${slim}\n`];
  for (const v of variants) {
    const t = bangs.checkedBangTable(v);
    checked.push([v.length, t !== null, t ? t.size : 0]);
  }
  const docs: unknown[] = [];
  const doc = bangs.bangDocument('"v2"', slim);
  for (const d of [doc, bangs.bangDocument(null, slim), "", slim, doc.slice(0, 2000), `ardia-bangs 2\t"v2"\n${slim}`, `ardia-bangs 1\t"v2"\tx\n${slim}`, `ardia-bangs 1\n${slim}`]) {
    const read = bangs.readBangDocument(d);
    docs.push([d === slim ? "slim" : d === doc ? "doc" : d.length > 3000 ? `len:${d.length}` : d, read ? { etag: read.etag, size: read.table.size, gh: read.table.get("gh") } : null]);
  }
  const bundled = bangs.joinBangTables([bangs.bangTable(BANG_LIST), bangs.bangTable(BANG_LIST_UNICODE)]);
  const triggers: string[] = [];
  for (const line of (BANG_LIST + "\n" + BANG_LIST_UNICODE).split("\n")) if (r.int(8) === 0) triggers.push(line.split("\t")[0]!.split(" ")[0]!);
  triggers.push("gh", "w", "yt", "ют", "t3", "GH", "Ют", "nope-not-a-bang", "", "a", "!gh");
  const bundledGets = triggers.map((t) => [t, bundled.get(t) ?? null]);
  const tableGets = ["gh", "GH", "git", "github", "ghr", "w", "wiki", "yt", "ют", "Ют", "zig", "gmail", "t3", "copilot", "ddg-chat", "ftp", "rtfd", "hypestat", "noslash", "port", "user", "sp", "s", "p", "sp2", "seven", "stored", "plainhttp", "site0", "site999", "nope", ""].map((t) => [t, table.get(t) ?? null]);
  return { helium: HELIUM, slim, size: table.size, tableGets, finds, terms, sites, loose, checked, docs, bundledSize: bundled.size, bundledGets };
}

const FUZZY_WORDS = ["new", "tab", "window", "incognito", "close", "all", "reload", "page", "Copy", "URL", "Markdown", "zoom", "in", "out", "Developer", "Tools", "dark", "mode", "Settings", "preferences", "clear", "browsing", "data", "history", "keyboard", "shortcuts", "Move", "to", "Top", "Apps", "pin", "unpin", "x", "a1", "9", "café", "naïve", "re-open", "(1)", "C++"];

function fuzzyCases() {
  const runs: unknown[] = [];
  for (let seed = 1; seed <= 150; seed++) {
    const r = rng(seed);
    const phrase = () => Array.from({ length: 1 + r.int(4) }, () => r.pick(FUZZY_WORDS)).join(r.int(6) ? " " : r.pick(["-", "  ", "\t", ", "]));
    const actions = Array.from({ length: r.int(60) }, (_, i) => ({ id: `a${i}`, title: phrase(), ...(r.int(2) ? { keywords: Array.from({ length: 1 + r.int(5) }, phrase) } : {}) }));
    const queries: unknown[] = [];
    for (let n = 0; n < 40; n++) {
      const source = actions.length && r.int(3) ? r.pick(actions) : null;
      const base = source ? r.pick([source.title, ...(source.keywords ?? [])]) : phrase();
      let query = base.slice(0, 1 + r.int(base.length));
      if (r.int(4) === 0) query = query.toUpperCase();
      if (r.int(5) === 0) query = ` ${query}  `;
      if (r.int(8) === 0) query = query.replace(/ /g, "   ");
      const limit = r.pick([3, 3, 1, 5, 100]);
      const matches = matchActions(query, actions, limit).map((m) => [m.action.id, m.score, m.exact]);
      queries.push([query, limit, matches, source ? fuzzyScore(query, source.title) : null, source?.title ?? null]);
    }
    runs.push({ actions, queries });
  }
  return runs;
}

const EXTENSIONS = [
  { id: "ublock", title: "uBlock Origin", icon: "data:image/png;base64,ublock", action: true, options: true },
  { id: "onepassword", title: "1Password – Password Manager", icon: "data:image/png;base64,onepassword", action: true, options: false },
  { id: "darkreader", title: "Dark Reader", icon: null, action: true, options: true },
  { id: "nopopup", title: "Video Speed Controller", icon: "data:image/png;base64,nopopup", action: false, options: true },
  { id: "ab", title: "AB", icon: null, action: true, options: true },
  { id: "none", title: "Neither Way", icon: null, action: false, options: false },
];

function smallCases() {
  const r = rng(61);
  const quick = ["new", "new ", "new doc", "NEW Doc", "create sheet", "new g", "new google", "new  google   doc", "newdoc", "create", "new ticket", "new issue", "new board", "new zzz", " new doc", "new\ndoc", "new doc\nx", "new \u2028doc", "new\u00a0doc", "new p", "create   ", "new w", "new wor"];
  for (let i = 0; i < 400; i++) quick.push(`${r.pick(["new", "New", "create", "CREATE", "neww"])}${r.pick([" ", "  ", "\t", ""])}${r.pick(["doc", "do", "d", "g", "goo", "google s", "issue", "ti", "", "word doc", "slides", "x"])}`);
  const quickCases = quick.map((q) => [q, matchQuickCreate(q).map((c) => c.id), matchQuickCreate(q, 1).map((c) => c.id), matchQuickCreate(q, 10).map((c) => c.id)]);

  const extQueries = ["ublock", "password", "reader", "video speed", "ub", "zzq", "ab", "AB", "dark rea", "Dark Reader", "ublock origin", "  ublock  ", "1password", "neither", "neither way", "sp", "spe", "speed", "origin"];
  const extCases = extQueries.map((q) => [q, extensionSuggestions(q, EXTENSIONS), extensionSuggestions(q, EXTENSIONS, 1), extensionSuggestions(q, [])]);

  const tabsCases: unknown[] = [];
  for (let i = 0; i < 200; i++) {
    const tabs = Array.from({ length: r.int(14) }, (_, k) => ({ id: `t${k}`, url: r.int(6) ? `https://${r.pick(["a", "b", "same"])}.example/` : "", title: `T${k}`, favicon: r.int(2) ? null : "f.ico", lastActiveAt: r.int(5) }));
    const exclude = r.int(3) ? undefined : `t${r.int(14)}`;
    const limit = r.int(3) ? undefined : r.int(10);
    tabsCases.push([tabs, exclude ?? null, limit ?? null, recentTabSuggestions(tabs, { exclude, limit })]);
  }
  return { quick: quickCases, extensions: { list: EXTENSIONS, cases: extCases }, tabs: tabsCases };
}

function engineCases() {
  const r = rng(71);
  const custom = [{ id: "c1", name: "My Wiki", keyword: "wk", url: "https://wiki.example/?q=%s" }, { id: "c2", name: "Docs", keyword: "D", url: "https://docs.example/search/%s" }];
  const ext = [
    { profile: "p", extensionId: "e1", extensionName: "Ext One", name: "One", keyword: "one", url: "https://one.example/?q=%s", suggestUrl: "", isDefault: false },
    { profile: "p", extensionId: "e2", extensionName: "Ext Two", name: "Two", keyword: "two", url: "https://two.example/?q=%s", suggestUrl: "https://two.example/s?q=%s", isDefault: true },
    { profile: "p", extensionId: "e1", extensionName: "Dup", name: "Dup", keyword: "dup", url: "https://dup.example/?q=%s", isDefault: true },
  ];
  const all = engines.allEngines(custom, ext);
  const inputs: unknown[] = [];
  const names = ["", " ", "My Engine", " Spaced "];
  const keywords = ["", " ", "wk", "WK", "google.com", "two words", "new", "  New  ", "d"];
  const urls = ["", "ftp://x/%s", "https://x.example/?q=%s", "https://x.example/", "http://", "https:// x/%s", "HTTPS://X.example/%s", "https:///%s", "https://?%s", "https://a#%s"];
  for (const name of names) for (const keyword of keywords) for (const url of urls) {
    const input = { name, keyword, url };
    inputs.push([input, engines.validateEngine(input, all), engines.validateEngine(input, all, "c1"), engines.makeCustomEngine(input, "id9")]);
  }
  const chromeLists: unknown[] = [
    { extensions: [{ extension: { id: "x1", name: "X One" }, name: "Search X", keyword: "x", url: "https://x.example/?q=%s&{google:RLZ}{a}", suggestionsUrl: "https://x.example/s?q=%s{google:x}", default: true }] },
    { a: [{ extension: { id: "x1" }, url: "https://x/%s" }, { extension: { id: "x1", name: "Again" }, url: "https://y/%s" }], b: [{ extension: { id: "x2", name: 5 }, url: "https://z/%s", isOmniboxExtension: true }] },
    { a: [{ extension: { id: "x3", name: ["n", ["m", null]] }, url: "https://z/%s", name: "", keyword: 7, suggestionsUrl: "https://nope/" }, null, 5, "s", [], { extension: null }, { extension: { id: 9 }, url: "https://q/%s" }] },
    { a: [{ extension: { id: "x4", name: { k: 1 } }, url: "https://z/{a%b}{}{c{d}}%s" }, { extension: { id: "x5", name: true }, url: "https://no-placeholder/" }, { extension: { id: "x6", name: null }, url: "https://n/%s", isOmniboxExtension: 0 }] },
    { 2: [{ extension: { id: "num2" }, url: "https://2/%s" }], 1: [{ extension: { id: "num1" }, url: "https://1/%s" }], z: [{ extension: { id: "z" }, url: "https://z/%s" }] },
    [[{ extension: { id: "arr" }, url: "https://arr/%s", isOmniboxExtension: "" }]],
    "string",
    null,
    5,
  ];
  const chrome = chromeLists.map((list) => [JSON.stringify(list), engines.extensionEnginesFromChrome("prof", list)]);
  const bodies = ['["q", ["a", " b ", "", "  ", 5, null, "c"]]', '["q"]', '{"a":1}', "[]", '["q", "notarray"]', '[1, [" x"]]', "null", '["q", []]'];
  const parsed = bodies.map((b) => [b, engines.parseSuggestions(JSON.parse(b))]);
  const queries = ["react", " ", "", " a b ", "日本", "100%"];
  const requests = engines.BUILT_IN_ENGINES.flatMap((e) => queries.map((q) => [e.id, q, engines.suggestRequestUrl(e, q), engines.searchUrl(e, q)]));
  return {
    custom,
    ext,
    all: all.map((e) => ({ ...e })),
    hosts: all.map((e) => [e.id, engines.engineHost(e)]),
    controlling: engines.controllingExtensionEngine(ext)?.extensionId ?? null,
    byId: ["bing", "nope", "c1", "extension:e2", ""].map((id) => [id, engines.engineById(all, id).id]),
    validate: inputs,
    chrome,
    parsed,
    requests,
  };
}

function siteSearchCases() {
  const r = rng(81);
  const hosts = ["docs.example.com", "github.com", "news.ycombinator.com", "intranet", "a.b.c"];
  const sources = { engines: engines.allEngines([{ id: "c1", name: "My Wiki", keyword: "wk", url: "https://wiki.example/?q=%s" }]), hosts };
  const texts = ["google", "google.com", "goo", "x.com", "www.youtube.com", "youtube", "https://github.com/", "GitHub.com", "wiki", "wk", "WK", "bing", "duck", "duckduckgo.com", "kagi", "ka", "yandex.com", "maps.google.com", "maps", "mail.google.com", "drive", "docs.example.com", "docs.example.com/", "intranet", "a.b.c", "notion", "notion.so", "app.notion.so", "spotify", "open.spotify.com", "hello world", "", "  ", "search.brave.com", "brave", "chatgpt", "perplexity.ai", "en.wikipedia.org", "wikipedia", "ycombinator", "news", "apple", "apps.apple.com", "x", "twitter", "co.uk", "ecosia.org"];
  for (let i = 0; i < 600; i++) texts.push(r.pick(texts) + r.pick(["", "/", " ", ".com", "x", "HTTP://"]));
  const scopes = texts.map((t) => [t, siteSearch.findScope(t, sources), siteSearch.findScope(t, { engines: engines.BUILT_IN_ENGINES })]);
  const offered = texts.slice(0, 200).map((t, i) => {
    const completion = ["", ".com", "gle.com", "ube.com", " x"][i % 5]!;
    return [t, completion, siteSearch.offeredSiteSearch(t, completion, sources)];
  });
  const spaces = [["x.com", "x.com "], ["x.com ", "x.com  "], ["x.com", "x.coma"], ["x.com", " x.com"], ["", " "], ["a\u00a0", "a\u00a0 "], ["ab", "ab\u00a0"], [" ", "  "]].map(([a, b]) => [a, b, siteSearch.keywordBySpace(a!, b!)]);
  const scope = siteSearch.findScope("x.com", sources)!;
  const keys: unknown[] = [];
  for (let i = 0; i < 400; i++) {
    const key = r.pick(["Tab", "Backspace", "Enter", "a"]);
    const mods = { shiftKey: !r.int(4), altKey: !r.int(5), metaKey: !r.int(5), ctrlKey: !r.int(5) };
    const typed = r.pick(["", "goo", "google", "x.com", "hello world"]);
    const completion = r.pick(["", ".com", "gle.com"]);
    const inScope = !r.int(3);
    const state = { typed, completion, scope: inScope ? scope : null, offered: inScope ? null : siteSearch.offeredSiteSearch(typed, completion, sources), scopeFrom: r.pick(["", "x.com", "x.com "]) };
    keys.push([key, mods, state, siteSearch.siteSearchKey(key, mods, state)]);
  }
  const scoped = [
    [{ kind: "history", name: "docs.example.com", host: "docs.example.com", url: "" }, " react  hooks "],
    [{ kind: "site", name: "GitHub", host: "github.com", url: "https://github.com/search?q=%s" }, "a b&c"],
    [{ kind: "engine", name: "Bing", host: "bing.com", url: "https://www.bing.com/search?q=%s", engineId: "bing" }, "日本"],
    [{ kind: "site", name: "Bang", host: "x.example", url: "https://x.example/{searchTerms}" }, "q"],
  ].map(([s, q]) => [s, q, siteSearch.scopedSearchUrl(s as siteSearch.SearchScope, q as string, engines.BUILT_IN_ENGINES[0]!)]);
  return { hosts, scopes, offered, spaces, keys, scoped };
}

function textFragmentCases() {
  const r = rng(91);
  const WORDS = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "Über", "naïve", "café", "日本語", "x_y", "a1", "-", "—", "it's", "end."];
  const sentence = (n: number) => Array.from({ length: n }, () => r.pick(WORDS)).join(r.pick([" ", "  ", " \n ", "\n", "\t"]));
  const cases: unknown[] = [];
  for (let i = 0; i < 700; i++) {
    const page = Array.from({ length: 1 + r.int(5) }, () => sentence(5 + r.int(30))).join("\n");
    const words = page.split(/(\s+)/);
    const from = r.int(words.length);
    const to = Math.min(words.length, from + 1 + r.int(40));
    const cut = (w: string) => (r.int(5) === 0 && w.length > 2 ? w.slice(1) : w);
    const selected = cut(words.slice(from, to).join(""));
    const before = words.slice(0, from).join("");
    const after = words.slice(to).join("");
    const context = { selected, before, after, pageText: page };
    const fragment = chooseTextFragment(context);
    const url = r.pick(["https://a.example/p", "https://a.example/p#sec", "https://a.example/p#sec:~:text=old", "https://a.example/p#:~:x", "https://a.example/p?q=1#"]);
    cases.push([context, fragment, fragment ? withTextFragment(url, fragment) : null, url]);
  }
  const direct = [
    [{ start: "a-b" }, "https://x/"],
    [{ prefix: "p", start: "s", end: "e", suffix: "x" }, "https://x/#h"],
    [{ prefix: "", start: "", end: "", suffix: "" }, "https://x/#h:~:text=a"],
    [{ start: "日本 語", end: "a,b" }, "https://x/#a#b"],
  ].map(([f, u]) => [f, u, withTextFragment(u as string, f as never)]);
  return { cases, direct };
}

const HOSTS = ["github.com", "www.github.com", "news.ycombinator.com", "notion.so", "x.com", "en.wikipedia.org", "react.dev", "example.org", "a.b.co.uk", "localhost:3000", "xn--nxasmq6b.com", "Docs.Google.com"];
const WORDS = ["react", "native", "banana", "nano", "layout", "github", "news", "notion", "an", "na", "net", "netflix", "pull", "issues", "perf", "Hermes", "Éclair", "naïve", "c++", "foo-bar", "a1", "9lives", "ok", "re\u00a0act", "tab\tbed", "new", "doc", "2+2", "5 km to mi", "ΟΔΟΣ", "İstanbul", "split", "settings"];
const TAILS = ["", "/", "?q=1", "#top", "/index.html", "?utm=a&b=c#x", "/react native", "/new tab/page"];
const NOW = Date.UTC(2026, 9, 6);
const DAY = 86_400_000;

type Row = { url: string; title: string; favicon: string | null; visits?: number; lastVisit?: number; id?: string };

function makeProfile(r: Rng, size: number) {
  const url = () => {
    const proto = r.int(12) ? "https" : "http";
    const path = Array.from({ length: r.int(4) }, () => r.pick(WORDS).toLowerCase()).join("/");
    return `${proto}://${r.pick(HOSTS)}/${path}${r.pick(TAILS)}`;
  };
  const title = () => (r.int(10) === 0 ? "" : Array.from({ length: 1 + r.int(6) }, () => r.pick(WORDS)).join(r.int(8) ? " " : "-"));
  const ties = r.int(2) === 0;
  const history = Array.from({ length: size }, () => ({
    url: url(),
    title: title(),
    favicon: r.int(3) ? `https://x/${r.int(9)}.ico` : null,
    visits: ties ? r.int(3) : r.int(5) ? 1 + r.int(40) : 0,
    lastVisit: ties ? NOW - r.int(3) * DAY : r.int(6) ? NOW - r.int(120 * DAY) : 0,
  }));
  const bookmarks = Array.from({ length: Math.floor(size / 4) }, () => {
    const h = r.int(2) && history.length ? r.pick(history) : null;
    return { url: h ? h.url : url(), title: h ? h.title : title(), favicon: null };
  });
  const tabs = Array.from({ length: Math.floor(size / 6) }, (_, i) => {
    const h = r.int(2) && history.length ? r.pick(history) : null;
    return { id: `t${i}`, url: r.int(15) ? (h ? h.url : url()) : "", title: h ? h.title : title(), favicon: null };
  });
  return { history, bookmarks, tabs };
}

const ACTIONS = [
  { id: "new-tab", title: "New Tab", keywords: ["create"] },
  { id: "settings", title: "Open Settings" },
  { id: "net-tools", title: "Network Tools", hint: "⌘N", icon: "wifi" },
  { id: "pin", title: "Pin Tab", keywords: ["keep"] },
  { id: "split", title: "Split View Side by Side", icon: "" },
];

const PROPERTY_EXTENSIONS = [
  { id: "ublock", title: "uBlock Origin", icon: null, action: true, options: true },
  { id: "notes", title: "Notion Web Clipper", icon: "n.png", action: false, options: true },
];

function sequence(r: Rng, p: ReturnType<typeof makeProfile>): string[] {
  const row = p.history.length ? r.pick(p.history) : { url: "https://github.com/", title: "GitHub" };
  const shown = row.url.replace(/^https?:\/\//, "");
  const targets = [shown, shown.replace(/^www\./, ""), row.title, row.title.split(/\s+/).slice(0, 3).join(" "), r.pick(HOSTS), `${r.pick(WORDS)} ${r.pick(WORDS)}`, r.pick(WORDS), `${r.pick(HOSTS)}/${r.pick(WORDS)}`];
  let target = r.pick(targets);
  if (r.int(5) === 0) target = target.toUpperCase();
  if (r.int(8) === 0) target = ` ${target} `;
  if (r.int(12) === 0) target = `?${target}`;
  if (r.int(12) === 0) target = `${r.pick(["yt", "gh", "g"])} ${target}`;
  if (r.int(8) === 0) target = r.int(2) ? `${r.pick(["!gh", "!W", "!nope", "!"])} ${target}` : `${target} ${r.pick(["!w", "!yt", "!", "!gh"])}`;
  if (r.int(15) === 0) target = `${r.pick(["new ", "create ", "https://", "HTTP://", "= "])}${target}`;
  const out: string[] = [];
  const upTo = Math.min(target.length, 4 + r.int(24));
  for (let i = 1; i <= upTo; i++) out.push(target.slice(0, i));
  for (let n = r.int(4); n > 0 && out.length; n--) {
    const last = out[out.length - 1]!;
    switch (r.int(5)) {
      case 0:
        out.push(last.slice(0, Math.max(0, last.length - 1 - r.int(3))));
        break;
      case 1:
        out.push(last + r.pick(WORDS).slice(0, 1 + r.int(3)));
        break;
      case 2:
        out.push(r.pick(WORDS).slice(0, 1 + r.int(4)));
        break;
      case 3:
        out.push(last + " ");
        break;
      default:
        out.push(last);
    }
  }
  return out.filter(wellFormed);
}

const BANG_TEXT = "gh git\tGitHub\tgithub.com/search?q={s}\nw wiki\tWikipedia\twikipedia.org/w/index.php?search={s}\nyt\tYouTube\twww.youtube.com/results?search_query={s}";
const BANGS = bangs.bangTable(BANG_TEXT);
const stats = { steps: 0, completions: 0, pages: 0, bangs: 0, scoped: 0, calcs: 0, actions: 0, creates: 0, extensions: 0 };

function recordRun(seed: number, size: number) {
  const r = rng(seed);
  const p = makeProfile(r, size);
  const scope = r.int(6) === 0 ? { kind: "site" as const, name: "GitHub", host: "github.com", url: "https://github.com/search?q=%s" } : null;
  const base: SuggestOptions = {
    now: NOW,
    limit: r.pick([8, 8, 8, 1, 3, 12]),
    engine: engines.BUILT_IN_ENGINES[r.int(3) ? 0 : 2]!,
    preference: r.int(4) ? "website" : "search",
    actions: ACTIONS,
    extensions: r.int(3) ? [] : PROPERTY_EXTENSIONS,
    currentTabId: r.int(3) ? undefined : `t${r.int(Math.max(1, p.tabs.length))}`,
    currentUrl: r.int(3) ? undefined : (p.history[r.int(Math.max(1, p.history.length))]?.url ?? undefined),
    scope,
    preventInline: r.int(6) === 0,
    bangs: r.int(4) ? BANGS : null,
  };
  const other = makeProfile(rng(seed + 100_000), size);
  const rows: Row[] = [];
  const ids = new Map<object, number>();
  const idOf = (row: Row) => {
    let id = ids.get(row);
    if (id === undefined) {
      id = rows.length;
      ids.set(row, id);
      rows.push(row);
    }
    return id;
  };
  let source: SuggestionSource = p;
  let last = { history: null as unknown, bookmarks: null as unknown, tabs: null as unknown };
  const steps: unknown[] = [];
  const queries = [...sequence(r, p), ...sequence(r, p)].flatMap((q) => (r.int(5) === 0 ? [q, q] : [q]));
  for (const [i, q] of queries.entries()) {
    if (r.int(7) === 0 && p.history.length) {
      const h = r.pick(p.history);
      source = { ...source, history: [{ ...h, visits: h.visits + 1, lastVisit: NOW }, ...source.history.filter((x) => x !== h)] };
    }
    if (r.int(11) === 0) source = { ...source, bookmarks: [...(source.bookmarks ?? [])] };
    if (r.int(9) === 0) source = { ...source, tabs: source.tabs.slice(r.int(3)) };
    if (r.int(10) === 0 && source.history.length) source = { ...source, history: source.history.filter((_, at) => at !== r.int(source.history.length)) };
    if (r.int(40) === 0) source = { ...source, history: [] };
    if (r.int(10) === 0 && source.tabs.length) {
      const at = r.int(source.tabs.length);
      source = { ...source, tabs: source.tabs.map((t, k) => (k === at ? { ...t, title: `${r.pick(WORDS)} ${t.title}` } : t)) };
    }
    if (r.int(12) === 0) source = { ...source, tabs: [...source.tabs, { id: `new${i}`, url: `https://${r.pick(HOSTS)}/${r.pick(WORDS)}`, title: r.pick(WORDS), favicon: null }] };
    if (r.int(10) === 0) {
      const h = source.history.length ? r.pick(source.history) : null;
      source = { ...source, bookmarks: [...(source.bookmarks ?? []), { url: h ? h.url : `https://${r.pick(HOSTS)}/${r.pick(WORDS)}`, title: h ? h.title : r.pick(WORDS), favicon: null }] };
    }
    if (r.int(10) === 0 && source.bookmarks?.length) source = { ...source, bookmarks: source.bookmarks.filter((_, at) => at !== r.int(source.bookmarks!.length)) };
    if (r.int(25) === 0) source = source === p ? other : p;
    const prepare = r.int(13) === 0;
    if (prepare) prepareSuggestions(source, Date.now() + 1);
    const options: SuggestOptions = { ...base, remote: r.int(3) ? [] : [`${q} one`, "two", q.toUpperCase(), `${q} three`, "four", "five", ` ${q} `, ""] };
    const want = reference.buildSuggestions(q, source, options);
    const got = buildSuggestions(q, source, options);
    if (!(options.extensions ?? []).length && JSON.stringify(want) !== JSON.stringify(got)) throw new Error(`reference disagrees: seed ${seed} step ${i} ${JSON.stringify(q)}`);
    const step: Record<string, unknown> = { q, expect: got };
    if (source.history !== last.history) step.history = source.history.map(idOf);
    if ((source.bookmarks ?? []) !== last.bookmarks) step.bookmarks = (source.bookmarks ?? []).map(idOf);
    if (source.tabs !== last.tabs) step.tabs = source.tabs.map(idOf);
    if (prepare) step.prepare = true;
    if (options.remote!.length) step.remote = options.remote;
    last = { history: source.history, bookmarks: source.bookmarks ?? [], tabs: source.tabs };
    steps.push(step);
    stats.steps++;
    if (got.completion) stats.completions++;
    if (got.items.some((x) => x.kind === "search" && x.bang)) stats.bangs++;
    if (options.scope) stats.scoped++;
    stats.pages += got.items.filter((x) => x.kind === "page").length;
    stats.calcs += got.items.filter((x) => x.kind === "calc").length;
    stats.actions += got.items.filter((x) => x.kind === "action").length;
    stats.creates += got.items.filter((x) => x.kind === "create").length;
    stats.extensions += got.items.filter((x) => x.kind === "extension").length;
  }
  return { seed, size, options: { ...base, engine: base.engine!.id, actions: undefined, bangs: base.bangs ? "test" : null }, rows, steps };
}

function suggestCases() {
  const runs: unknown[] = [];
  for (let seed = 1; seed <= RUNS; seed++) runs.push(recordRun(seed, 1 + (seed % 7) * 25));
  for (let seed = 9001; seed < 9001 + BIG; seed++) runs.push(recordRun(seed, 1500));
  runs.push(recordRun(77, 0), recordRun(78, 1));
  const edge: unknown[] = [];
  const source = {
    history: [{ url: "https://history.example/", title: "abc", favicon: null, visits: 2, lastVisit: 0 }],
    tabs: [{ id: "t", url: "https://tab.example/", title: "abc", favicon: null }],
    bookmarks: [],
  };
  for (const now of [0, NaN, Infinity, 1]) edge.push([source, num(now), "search", "abc", buildSuggestions("abc", source, { now, preference: "search" })]);
  const twins = { tabs: [], bookmarks: [], history: [2, 20].map((visits, i) => ({ url: `https://t${i}.example/`, title: "abc", favicon: null, visits, lastVisit: 1 })) };
  for (const now of [NaN, Infinity]) edge.push([twins, num(now), "website", "abc", buildSuggestions("abc", twins, { now })]);
  console.log(JSON.stringify(stats));
  return { actions: ACTIONS, extensions: PROPERTY_EXTENSIONS, bangs: BANG_TEXT, runs, edge, stats };
}

const WHATWG_PIECES = [
  "http:", "https:", "HTTP:", "file:", "ftp:", "ws:", "wss:", "ardia:", "chrome:", "mailto:", "about:", "data:", "javascript:", "foo:", "a+b-c.d:", "1x:", "//", "/", "\\", "///", "\\\\", "/\\",
  "example.com", "EXAMPLE.com", "localhost", "LocalHost", "user", "user:pw", ":pw", "@", "a@b@", "%40", "[::1]", "[2001:DB8::0:1]", "[::ffff:1.2.3.4]", "[1:2:3:4:5:6:7:8]", "[1::2::3]", "[::1", "[zz]",
  "127.0.0.1", "0x7f.1", "0300.0.0.1", "1.2.3.4.5", "256.0.0.1", "4294967295", "4294967296", "1.2.3.", "0x", "09", "1.0x", "münchen", "xn--bcher-kva", "xn--zz", "ＥＸＡＭＰＬＥ", "a\u00adb", "%65xample",
  "%zz", "%", "exa mple", "a<b", "a^b", "a|b", "a%00b", "\u0000", "\u007f", ":", ":80", ":443", ":8080", ":0080", ":65536", ":abc", ":", "?", "?q=a b'\"<>`", "#", "#frag ment`<>\"", "/a/../b",
  "/./a", "/a/%2e%2E/b", "/a/.%2e", "/..", "/C:", "/c|", "C|", "c:", "/a b", "/a?b", "/é", "/%41", "\t", "\n", " ", "\u0001", "😀", "{}", "^", "`", "|", ";", "=", "~", "!", "'", "*",
];
function whatwgCases() {
  const r = rng(101);
  const inputs = ["https://example.com", "https://user:pw@example.com:8443/p?q#h", "file:///Users/me/a%20b.html", "file://localhost/x", "file://host/share", "file:C:/x", "file:///C|/x/../..", "ardia://flags", "chrome://version/", "mailto:hi@example.com", "about:blank", "data:text/plain,hi", "javascript:alert(1)", "http://[::1]:80/", "https://0x7f.1/", "https://ＥＸＡＭＰＬＥ.com/", "  https://a.com/ \t", "https://a\nb.com", "foo://", "foo:///", "foo://h:1/p", "foo:/p/../q", "foo:/.//p", "sc: x ?q", "non-spec:/.//", "https://a.com:443", "http://a.com:080", "ws://a:80", "ftp://a:21/x", "http://example.com/foo/%2e%2", "http://a/b/c/../../..", "https://%E2%82%AC.com"];
  for (let i = 0; i < 6000; i++) {
    let s = r.int(8) ? r.pick(WHATWG_PIECES.slice(0, 15)) : "";
    for (let k = 1 + r.int(7); k > 0; k--) s += r.pick(WHATWG_PIECES);
    inputs.push(s);
  }
  return inputs.filter(wellFormed).map((input) => {
    try {
      const u = new URL(input);
      return [input, { protocol: u.protocol, username: u.username, password: u.password, hostname: u.hostname, host: u.host, port: u.port, pathname: u.pathname, search: u.search, hash: u.hash, href: u.href }];
    } catch {
      return [input, null];
    }
  });
}

write("lower.json", lowerCases());
write("whatwg.json", whatwgCases());
write("numbers.json", numberCases());
write("log2.json", log2Cases());
write("urls.json", urlCases());
write("idn.json", idnCases());
write("calc.json", calcCases());
write("bangs.json", bangCases());
write("fuzzy.json", fuzzyCases());
write("small.json", smallCases());
write("engines.json", engineCases());
write("siteSearch.json", siteSearchCases());
write("textFragment.json", textFragmentCases());
write("suggest.json", suggestCases());
