//! What a port share answers while nothing listens on its port: a small page that says so,
//! or the bare status for a request that is not a page load.
//!
//! The page stands alone: its picture, style and script are inside it, and it asks nothing of
//! any other address. It follows the browser's light or dark appearance. Every five seconds
//! its script asks for the same address again and loads the real page as soon as an answer
//! comes without the header that marks this one. A dev server can't set that header itself:
//! the share takes it out of every answer it passes on (proxy.rs).

use crate::brand::APP;

/// The header that marks an answer as the share's own, not the dev server's.
pub const HEADER: &str = concat!("X-", crate::app_name!(), "-Waiting");

/// The link that brings the phone app forward and changes nothing in it (docs/glance.md).
const OPEN_APP: &str = "rexduo://open";

/// How long a browser is told to wait before it asks again, and how often the page does.
const RETRY_SECONDS: u32 = 5;

/// The most characters of the computer's name the page shows.
const NAME_LIMIT: usize = 64;

/// The page is never larger than this, whatever the computer is called.
#[cfg(test)]
pub const PAGE_LIMIT: usize = 8 * 1024;

/// The glyph of Brand/glyph.svg: its view box and its one path. A test holds the two together.
const GLYPH_BOX: &str = "88 132 845 759";
const GLYPH_PATH: &str = "M549.91 882.24C578.39 880.69 606.43 872.47 631.38 858.70C658.75 843.61 683.25 821.44 699.07 794.30C733.08 736.01 739.35 633.85 734.86 567.31C733.42 546.02 734.71 518.96 755.36 506.70C761.39 503.12 768.38 501.48 775.30 500.73C786.68 499.48 798.37 500.54 809.77 501.02C830.25 501.89 850.72 503.17 871.17 504.48C881.19 505.13 892.69 507.52 902.53 504.96C913.32 502.16 921.84 493.31 924.23 482.42C929.32 459.23 911.28 450.75 894.67 441.35C885.97 436.43 877.25 431.53 868.54 426.62C855.48 419.24 842.42 411.86 829.42 404.37C819.48 398.65 809.22 393.22 800.51 385.65C788.87 375.54 780.01 362.05 774.11 347.86C771.03 340.46 768.54 332.87 765.24 325.56C759.07 311.89 751.60 298.79 742.92 286.56C712.85 244.20 673.46 230.71 626.08 215.95C609.13 210.67 591.49 204.71 573.82 202.46C570.85 202.08 567.85 202.32 564.86 202.04C559.39 201.52 553.97 200.56 548.48 200.14C538.50 199.38 528.50 199.36 518.53 198.48C502.52 197.07 486.88 194.15 471.17 190.88C380.08 171.95 288.37 156.79 195.97 145.99C185.54 144.77 175.12 143.57 164.69 142.45C152.98 141.19 140.59 138.44 128.96 141.46C106.38 147.32 92.05 170.70 97.09 193.48C99.69 205.27 107.21 215.66 117.60 221.81C126.10 226.84 136.48 228.73 145.88 231.48C158.34 235.12 170.76 238.97 183.13 242.94C238.32 260.66 292.84 280.71 345.59 304.81C366.00 314.13 389.15 322.62 404.89 339.21C420.34 355.50 426.26 377.45 432.66 398.36C443.29 433.08 453.96 452.86 478.77 479.58C489.48 491.10 502.23 502.07 509.61 516.18C514.51 525.56 516.10 536.71 510.43 546.16C503.28 558.08 488.50 562.35 475.43 563.11C450.68 564.56 425.54 556.47 401.73 550.71C361.87 541.07 322.34 530.15 283.09 518.29C257.72 510.63 232.47 502.62 207.18 494.70C188.51 488.85 153.16 476.63 134.45 477.64C112.19 478.85 99.28 496.16 104.66 517.92C109.94 539.31 143.29 593.89 160.08 607.82C173.84 619.25 192.33 621.00 208.83 626.08C222.22 630.20 234.79 636.89 245.68 645.70C260.86 657.99 272.63 674.31 279.48 692.61C282.75 701.33 283.77 711.58 290.46 718.57C301.21 729.80 322.51 729.46 336.77 734.01C349.64 738.10 361.83 744.30 372.72 752.28C389.68 764.72 403.37 781.43 412.22 800.51C420.19 817.68 425.62 836.55 440.15 849.62C448.48 857.11 458.88 860.87 468.69 865.91C471.80 867.51 474.60 869.61 477.84 870.98C500.18 880.43 525.84 883.55 549.91 882.24ZM632.95 407.69C644.14 407.48 654.46 401.73 661.16 392.87C668.14 383.63 671.01 371.73 670.05 360.28C669.14 349.32 664.76 338.60 657.41 330.37C649.73 321.78 638.73 316.09 627.05 316.31C615.86 316.52 605.54 322.27 598.84 331.13C591.86 340.37 588.99 352.27 589.95 363.72C590.86 374.68 595.24 385.40 602.59 393.63C610.27 402.22 621.27 407.91 632.95 407.69Z";

/// `text` as HTML shows it as text: nothing in it opens a tag, ends an attribute or starts
/// an entity. Control characters are left out and the rest is cut at `NAME_LIMIT`.
pub fn escape(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars().filter(|c| !c.is_control()).take(NAME_LIMIT) {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// The page for a share of `port` on the computer called `machine`.
pub fn page(port: u16, machine: &str) -> String {
    let machine = match escape(machine.trim()) {
        name if name.is_empty() => "this computer".to_string(),
        name => name,
    };
    format!(
        concat!(
            "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
            "<title>localhost:{port}</title><style>",
            ":root{{color-scheme:light dark;--bg:#fff;--fg:#1c1c1e;--dim:#8e8e93;--on:#fff}}",
            "@media(prefers-color-scheme:dark){{:root{{--bg:#000;--fg:#f2f2f7;--dim:#8e8e93;--on:#000}}}}",
            "html,body{{height:100%;margin:0}}",
            "body{{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:22px;",
            "padding:24px;box-sizing:border-box;background:var(--bg);color:var(--fg);",
            "font:17px/1.4 -apple-system,system-ui,sans-serif;text-align:center}}",
            "svg{{width:72px;height:auto;color:var(--dim)}}",
            "p{{margin:0;max-width:22em;overflow-wrap:anywhere}}",
            "a{{padding:12px 22px;border-radius:999px;background:var(--fg);color:var(--on);",
            "text-decoration:none;font-weight:600}}",
            "</style></head><body>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{view}\" aria-hidden=\"true\">",
            "<path fill=\"currentColor\" fill-rule=\"evenodd\" d=\"{glyph}\"/></svg>",
            "<p>Nothing is running on localhost:{port} on {machine} right now.</p>",
            "<a href=\"{link}\">Open {app}</a>",
            "<script>setInterval(function(){{fetch(location.href,{{cache:\"no-store\"}}).then(function(r){{",
            "if(!r.headers.get(\"{header}\"))location.reload()}}).catch(function(){{}})}},{every}000)</script>",
            "</body></html>"
        ),
        port = port,
        view = GLYPH_BOX,
        glyph = GLYPH_PATH,
        machine = machine,
        link = OPEN_APP,
        app = APP,
        header = HEADER,
        every = RETRY_SECONDS,
    )
}

/// The whole answer, head and body: `503` with the page when `page` is true (a plain `GET`),
/// and the bare status otherwise. Either way the browser is told when to ask again and to
/// keep no copy, the answer carries `HEADER`, and the connection ends with it.
pub fn response(port: u16, machine: &str, page: bool) -> Vec<u8> {
    let body = if page { self::page(port, machine) } else { String::new() };
    let kind = if page { "Content-Type: text/html; charset=utf-8\r\n" } else { "" };
    format!(
        "HTTP/1.1 503 Service Unavailable\r\n{kind}Content-Length: {}\r\nRetry-After: {RETRY_SECONDS}\r\nCache-Control: no-store\r\n{HEADER}: 1\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_says_what_is_missing_where_and_how_to_get_back() {
        let page = page(3000, "desk");
        assert!(page.contains("<p>Nothing is running on localhost:3000 on desk right now.</p>"), "{page}");
        assert!(page.contains(&format!("<a href=\"rexduo://open\">Open {APP}</a>")));
        assert!(page.contains("<title>localhost:3000</title>"));
        // Light and dark, and the system's own font.
        assert!(page.contains("prefers-color-scheme:dark") && page.contains("color-scheme:light dark"));
        assert!(page.contains("-apple-system,system-ui"));
        // It asks for its own address every five seconds, never from a cache, and loads the
        // real page only when the answer no longer carries the header.
        assert!(page.contains("fetch(location.href,{cache:\"no-store\"})"));
        assert!(page.contains(&format!("if(!r.headers.get(\"{HEADER}\"))location.reload()")));
        assert!(page.contains("},5000)</script>"));
        assert_eq!(HEADER, format!("X-{APP}-Waiting"));
    }

    #[test]
    fn the_page_stands_alone_and_is_small() {
        let page = page(65535, &"m".repeat(500));
        assert!(page.len() < PAGE_LIMIT, "{} bytes", page.len());
        // Nothing is loaded from anywhere: the only addresses in it are the SVG namespace
        // (a name, never fetched) and the link that opens the app.
        let addresses: Vec<&str> = page.match_indices("://").map(|(i, _)| &page[i.saturating_sub(6)..i + 3]).collect();
        assert_eq!(addresses, ["=\"http://", "rexduo://"], "{page}");
        assert_eq!(page.matches("http://www.w3.org/2000/svg").count(), 1);
        for loads in ["src=", "<link", "@import", "url(", "<img", "<iframe"] {
            assert!(!page.contains(loads), "{loads}");
        }
        assert!(page.is_ascii());
    }

    #[test]
    fn a_hostile_computer_name_is_only_ever_text() {
        let hostile = "</p><script>alert(1)</script><img src=x onerror=\"a\" 'b'>&amp;\u{0}\u{1b}\n";
        let page = page(3000, hostile);
        assert!(page.contains("on &lt;/p&gt;&lt;script&gt;alert(1)&lt;/script&gt;&lt;img src=x onerror=&quot;a&quot; &#39;b&#39;&gt;&amp;amp; right now."), "{page}");
        // One script (the page's own), one paragraph, no tag the name brought.
        assert_eq!((page.matches("<script").count(), page.matches("<p>").count(), page.matches("<img").count()), (1, 1, 0));
        assert_eq!(escape("a<b>&\"'c"), "a&lt;b&gt;&amp;&quot;&#39;c");
        // A long name is cut, in characters, and a name of nothing has a stand-in.
        assert_eq!(escape(&"é".repeat(200)).chars().count(), NAME_LIMIT);
        assert!(self::page(3000, " \n ").contains("on this computer right now."));
    }

    #[test]
    fn the_answer_tells_a_browser_to_come_back_and_keep_nothing() {
        let full = String::from_utf8(response(3000, "desk", true)).unwrap();
        let (head, body) = full.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("HTTP/1.1 503 Service Unavailable\r\n"), "{head}");
        for line in ["Content-Type: text/html; charset=utf-8", "Retry-After: 5", "Cache-Control: no-store", &format!("{HEADER}: 1"), "Connection: close", &format!("Content-Length: {}", body.len())] {
            assert!(head.split("\r\n").any(|l| l == line), "{line} in {head}");
        }
        assert_eq!(body, page(3000, "desk"));
        // Anything that is not a page load gets the status alone.
        let bare = String::from_utf8(response(3000, "desk", false)).unwrap();
        let (head, body) = bare.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("HTTP/1.1 503 ") && body.is_empty());
        assert!(head.contains("Content-Length: 0\r\n") && head.contains(&format!("{HEADER}: 1")) && head.contains("Retry-After: 5"));
        assert!(!head.contains("Content-Type"));
    }

    /// The glyph is the brand's: the same view box and path as Brand/glyph.svg, when this
    /// crate is built inside the repository.
    #[test]
    fn the_glyph_is_the_brands() {
        let brand = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../Brand/glyph.svg");
        let Ok(svg) = std::fs::read_to_string(brand) else { return };
        assert!(svg.contains(&format!("viewBox=\"{GLYPH_BOX}\"")));
        assert!(svg.contains(&format!(" d=\"{GLYPH_PATH}\"")));
    }
}
