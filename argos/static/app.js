/* Argos front end.
 *
 * Deliberately framework-free and small: the heavy lifting (search, valuation,
 * slide layout, charts) happens in Python, and this file is the thin layer that
 * moves JSON onto the screen. Charts and deck slides arrive as server-rendered
 * markup from the same renderers the exports use, so nothing here re-implements
 * a layout that also exists in the deck.
 */

const state = {
  route: "dashboard",
  query: "",
  filters: { doc_type: [], ticker: [], sentiment: null },
  expand: true,
  results: [],
  activeDocument: null,
  companies: [],
  activeCompany: null,
  pitchbooks: [],
  activeBook: null,
  exportFormats: { html: true },
  pinTarget: null,
};

// Example chips adapt to whatever corpus is loaded: the ticker-scoped
// examples use the first company in the database rather than a demo name.
const exampleQueries = (ticker) => [
  "pricing pressure",
  '"backlog" OR "order book"',
  "guidance type:press-release",
  "margin -restructuring",
  "tariff OR datacenter",
  `ticker:${ticker || "NVG"} cash flow`,
];

/* ----------------------------------------------------------------- utils */

const $ = (selector, scope = document) => scope.querySelector(selector);
const $$ = (selector, scope = document) => Array.from(scope.querySelectorAll(selector));

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "html") node.innerHTML = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2), value);
    else if (key === "dataset") Object.assign(node.dataset, value);
    else node.setAttribute(key, value);
  }
  for (const child of [].concat(children)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `${response.status} ${response.statusText}`);
  return payload;
}

let toastTimer;
function toast(message) {
  const node = $("#toast");
  node.textContent = message;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, 3200);
}

const money = (value, currency = "USD") => {
  if (value === null || value === undefined) return "n/a";
  const symbol = { USD: "$", EUR: "€", GBP: "£" }[currency] || "";
  const amount = Number(value);
  return Math.abs(amount) >= 1000
    ? `${symbol}${(amount / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 })}bn`
    : `${symbol}${amount.toLocaleString(undefined, { maximumFractionDigits: 0 })}m`;
};
const price = (value, currency = "USD") => value === null || value === undefined
  ? "n/a"
  : `${{ USD: "$", EUR: "€", GBP: "£" }[currency] || ""}${Number(value).toFixed(2)}`;
const pct = (value, digits = 1) => value === null || value === undefined ? "n/a" : `${(Number(value) * 100).toFixed(digits)}%`;
const mult = (value) => value === null || value === undefined ? "n/a" : `${Number(value).toFixed(1)}x`;
const num = (value, digits = 0) => value === null || value === undefined
  ? "n/a" : Number(value).toLocaleString(undefined, { maximumFractionDigits: digits });

function sentimentPill(score, label) {
  const value = Number(score || 0);
  const tone = value >= 0.18 ? "pos" : value <= -0.18 ? "neg" : "";
  return el("span", { class: `pill ${tone}`, title: "Document tone" }, `${label || (value >= 0 ? "positive" : "negative")} ${value >= 0 ? "+" : ""}${value.toFixed(2)}`);
}

/** replaceChildren with a literal null renders the text "null", so filter. */
function fill(container, ...nodes) {
  container.replaceChildren(...nodes.flat().filter(Boolean));
  return container;
}

function spinner(container, message = "Loading…") {
  container.replaceChildren(el("p", { class: "spinner" }, message));
}

/* --------------------------------------------------------------- routing */

function setRoute(route) {
  state.route = route;
  $$(".tab").forEach((tab) => {
    const active = tab.dataset.route === route;
    tab.setAttribute("aria-current", active ? "page" : "false");
  });
  $$(".view").forEach((view) => { view.hidden = view.id !== `view-${route}`; });
  if (location.hash.slice(1) !== route) history.replaceState(null, "", `#${route}`);
  const loaders = {
    dashboard: loadDashboard,
    research: () => { if (!state.results.length) runSearch(); },
    companies: loadCompanies,
    pitchbooks: loadPitchbooks,
    monitor: loadMonitor,
  };
  loaders[route]?.();
}

/* ------------------------------------------------------------- dashboard */

async function loadDashboard() {
  const tiles = $("#dashboard-tiles");
  if (tiles.childElementCount) return;
  spinner(tiles);
  try {
    const [overview, chartSvg] = await Promise.all([api("/api/overview"), api("/api/dashboard-charts")]);
    $("#corpus-stamp").textContent = `${num(overview.counts.documents)} documents · as of ${overview.as_of}`;
    $("#dashboard-sub").textContent =
      `${num(overview.counts.documents)} documents across ${overview.counts.companies} companies, `
      + `${num(overview.counts.chunks)} indexed passages and ${num(overview.counts.kpis)} extracted metrics.`;

    const distribution = Object.fromEntries((overview.sentiment.distribution || []).map((row) => [row.value, row.count]));
    tiles.replaceChildren(
      tile("Documents", num(overview.counts.documents), `${overview.by_type.length} document types`),
      tile("Companies covered", num(overview.counts.companies), `${num(overview.counts.transactions)} precedent deals`),
      tile("Extracted metrics", num(overview.counts.kpis), "KPIs parsed from narrative text"),
      tile("Mean tone", `${overview.sentiment.mean >= 0 ? "+" : ""}${overview.sentiment.mean.toFixed(2)}`,
        `${distribution.positive || 0} positive / ${distribution.negative || 0} negative`),
      tile("Pitch books", num(overview.counts.pitchbooks), "decks built from this corpus"),
    );
    $("#dashboard-sentiment").innerHTML = chartSvg.sentiment;
    $("#dashboard-volume").innerHTML = chartSvg.volume;

    $("#dashboard-themes").replaceChildren(el("div", { class: "examples" },
      (overview.trending || []).map((theme) => el("button", {
        class: "chip", type: "button",
        title: `${theme.mentions} documents recently vs ${theme.prior_mentions} before (${theme.lift}x)`,
        onclick: () => { $("#q").value = `"${theme.theme}"`; setRoute("research"); runSearch(); },
      }, `${theme.theme} · ${theme.lift}x`))));

    $("#dashboard-coverage").replaceChildren(dataTable(
      [
        { key: "ticker", label: "Ticker" },
        { key: "name", label: "Company" },
        { key: "documents", label: "Docs", numeric: true },
        { key: "sentiment", label: "Tone", numeric: true, render: (v) => v === null ? "n/a" : `${v >= 0 ? "+" : ""}${Number(v).toFixed(2)}` },
        { key: "latest", label: "Latest" },
      ],
      overview.coverage,
      (row) => { state.activeCompany = row.ticker; setRoute("companies"); },
    ));

    $("#dashboard-recent").replaceChildren(...overview.recent.map(documentCard));
  } catch (error) {
    tiles.replaceChildren(el("p", { class: "empty" }, `Could not load the dashboard: ${error.message}`));
  }
}

function tile(label, value, delta) {
  return el("div", { class: "tile" }, [
    el("div", { class: "label" }, label),
    el("div", { class: "value" }, value),
    delta ? el("div", { class: "delta" }, delta) : null,
  ]);
}

function dataTable(columns, rows, onRowClick) {
  const head = el("tr", {}, columns.map((column) => el("th", { class: column.numeric ? "num" : "", scope: "col" }, column.label)));
  const body = rows.map((row) => el("tr", {
    class: [onRowClick ? "clickable" : "", row.is_target ? "is-highlight" : ""].filter(Boolean).join(" "),
    tabindex: onRowClick ? "0" : null,
    onclick: onRowClick ? () => onRowClick(row) : null,
    onkeydown: onRowClick ? (event) => { if (event.key === "Enter") onRowClick(row); } : null,
  }, columns.map((column) => el("td", { class: column.numeric ? "num" : "" },
    column.render ? column.render(row[column.key], row) : (row[column.key] ?? "n/a")))));
  return el("div", { class: "table-scroll" }, el("table", {}, [el("thead", {}, head), el("tbody", {}, body)]));
}

function documentCard(row) {
  return el("article", {
    class: "result", tabindex: "0",
    onclick: () => openDocument(row.id || row.document_id),
    onkeydown: (event) => { if (event.key === "Enter") openDocument(row.id || row.document_id); },
  }, [
    el("div", { class: "title" }, row.title),
    el("div", { class: "meta" }, [
      row.ticker ? el("span", { class: "pill ticker" }, row.ticker) : null,
      el("span", { class: "pill" }, row.doc_type),
      el("span", {}, row.published_at),
      sentimentPill(row.sentiment),
    ]),
  ]);
}

/* ---------------------------------------------------------------- search */

function buildSearchUrl() {
  const params = new URLSearchParams();
  if (state.query) params.set("q", state.query);
  state.filters.doc_type.forEach((value) => params.append("doc_type", value));
  state.filters.ticker.forEach((value) => params.append("ticker", value));
  if (state.filters.sentiment) params.set("sentiment", state.filters.sentiment);
  params.set("limit", "25");
  params.set("expand", state.expand ? "1" : "0");
  return `/api/search?${params.toString()}`;
}

async function runSearch() {
  state.query = $("#q").value.trim();
  state.expand = $("#expand").checked;
  const results = $("#results");
  spinner(results, "Searching…");
  try {
    const payload = await api(buildSearchUrl());
    state.results = payload.results;
    renderMeta(payload);
    renderFacets(payload.facets);
    renderSummary(payload.summary);
    renderResults(payload.results);
  } catch (error) {
    results.replaceChildren(el("p", { class: "empty" }, `Search failed: ${error.message}`));
  }
}

function renderMeta(payload) {
  const bits = [`${payload.total_documents} document${payload.total_documents === 1 ? "" : "s"}`, `${payload.took_ms} ms`];
  if (payload.expanded && payload.match_expression) bits.push(`matched on ${payload.match_expression}`);
  $("#results-meta").textContent = bits.join(" · ");
}

function renderFacets(facets) {
  const container = $("#facets");
  const groups = [
    { key: "doc_type", title: "Document type", multi: true },
    { key: "ticker", title: "Company", multi: true },
    { key: "sentiment", title: "Tone", multi: false },
    { key: "year", title: "Year", multi: false, readonly: true },
  ];
  container.replaceChildren(...groups.flatMap((group) => {
    const rows = facets?.[group.key] || [];
    if (!rows.length) return [];
    return [el("div", { class: "facet-group" }, [
      el("h3", {}, group.title),
      ...rows.map((row) => {
        const selected = group.multi
          ? state.filters[group.key]?.includes(row.value)
          : state.filters[group.key] === row.value;
        return el("button", {
          class: "facet-item", type: "button", "aria-pressed": String(Boolean(selected)),
          onclick: () => {
            if (group.readonly) { $("#q").value = `${state.query} ${row.value}`.trim(); runSearch(); return; }
            if (group.multi) {
              const list = state.filters[group.key];
              const index = list.indexOf(row.value);
              if (index >= 0) list.splice(index, 1); else list.push(row.value);
            } else {
              state.filters[group.key] = selected ? null : row.value;
            }
            runSearch();
          },
        }, [el("span", {}, row.value), el("span", { class: "count" }, row.count)]);
      }),
    ])];
  }));
  if (!container.childElementCount) container.replaceChildren(el("p", { class: "empty" }, "No filters."));
}

function renderSummary(summary) {
  const container = $("#summary");
  if (!summary || !summary.bullets?.length) { container.replaceChildren(); return; }
  container.replaceChildren(el("div", { class: "summary-card" }, [
    el("h2", {}, "What the top matches say"),
    el("ul", {}, summary.bullets.map((bullet) => el("li", {}, [
      bullet.text,
      el("span", { class: "cite" }, `${bullet.ticker || "—"} · ${bullet.title} · ${bullet.published_at}`),
    ]))),
    el("p", { class: "small muted" }, [
      `Aggregate tone ${summary.sentiment >= 0 ? "+" : ""}${summary.sentiment} (${summary.sentiment_label}).`,
      summary.themes?.length ? ` Themes: ${summary.themes.slice(0, 6).map((t) => t.theme).join(", ")}.` : "",
    ].join("")),
  ]));
}

function renderResults(results) {
  const container = $("#results");
  if (!results.length) {
    container.replaceChildren(el("p", { class: "empty" }, "No matches. Try fewer terms, or switch synonym expansion on."));
    return;
  }
  fill(container, ...results.map((row) => el("article", {
    class: `result${state.activeDocument === row.document_id ? " is-active" : ""}`,
    tabindex: "0",
    onclick: () => openDocument(row.document_id),
    onkeydown: (event) => { if (event.key === "Enter") openDocument(row.document_id); },
  }, [
    el("div", { class: "title" }, row.title),
    el("div", { class: "meta" }, [
      row.ticker ? el("span", { class: "pill ticker" }, row.ticker) : null,
      el("span", { class: "pill" }, row.doc_type),
      el("span", {}, row.published_at),
      row.source ? el("span", {}, row.source) : null,
      sentimentPill(row.chunk_sentiment, row.sentiment_label),
      row.match_count > 1 ? el("span", { class: "pill" }, `${row.match_count} passages`) : null,
    ]),
    el("p", { class: "snippet", html: row.snippet_html }),
    el("div", { class: "actions" }, [
      el("button", {
        class: "ghost small", type: "button",
        onclick: (event) => {
          event.stopPropagation();
          openPinDialog({ quote: stripHtml(row.snippet_html), document_id: row.document_id, chunk_id: row.chunk_id });
        },
      }, "Pin to deck"),
    ]),
  ])));
}

const stripHtml = (markup) => {
  const node = document.createElement("div");
  node.innerHTML = markup;
  return node.textContent.replace(/^…|…$/g, "").trim();
};

async function openDocument(documentId) {
  state.activeDocument = documentId;
  renderResults(state.results);
  const reader = $("#reader");
  spinner(reader, "Opening document…");
  try {
    const doc = await api(`/api/documents/${documentId}?q=${encodeURIComponent(state.query)}`);
    fill(reader,
      el("div", { class: "panel" }, [
        el("h2", {}, doc.title),
        el("div", { class: "meta small muted" }, [
          doc.ticker ? `${doc.ticker} · ` : "",
          `${doc.doc_type} · ${doc.published_at}${doc.source ? ` · ${doc.source}` : ""} · ${num(doc.word_count)} words`,
        ].join("")),
        el("p", { class: "small", style: "margin-top:8px" }, doc.summary.join(" ")),
        doc.keywords?.length
          ? el("div", { class: "examples" }, doc.keywords.slice(0, 8).map((k) => el("span", { class: "pill" }, k.theme)))
          : null,
      ]),
      doc.kpis?.length ? el("div", { class: "panel" }, [
        el("h2", {}, "Extracted metrics"),
        dataTable([
          { key: "metric", label: "Metric", render: (v) => v.replace(/_/g, " ") },
          { key: "value", label: "Value", numeric: true, render: (v, row) => `${num(v, 1)}${row.unit === "%" ? "%" : ""}` },
          { key: "period", label: "Period" },
        ], doc.kpis),
      ]) : null,
      el("div", { class: "panel" }, [
        el("h2", {}, `Passages (${doc.chunks.length})`),
        ...doc.chunks.map((chunk) => el("div", {
          class: `passage ${chunk.sentiment >= 0.18 ? "pos" : chunk.sentiment <= -0.18 ? "neg" : ""}`,
        }, [
          chunk.speaker ? el("span", { class: "speaker" }, chunk.speaker) : null,
          el("span", {}, chunk.text),
          el("div", { class: "pin" }, el("button", {
            class: "ghost small", type: "button",
            onclick: () => openPinDialog({ quote: chunk.text, document_id: doc.id, chunk_id: chunk.id }),
          }, "Pin to deck")),
        ])),
      ]),
      doc.similar?.length ? el("div", { class: "panel" }, [
        el("h2", {}, "Similar documents"),
        ...doc.similar.map((row) => el("button", {
          class: "company-item", type: "button", onclick: () => openDocument(row.document_id),
        }, [
          el("span", {}, row.title),
          el("span", { class: "sub" }, `${row.ticker || "—"} · ${row.doc_type} · ${row.published_at} · similarity ${row.similarity}`),
        ])),
      ]) : null,
    );
  } catch (error) {
    reader.replaceChildren(el("p", { class: "empty" }, `Could not open document: ${error.message}`));
  }
}

/* ------------------------------------------------------------- companies */

async function loadCompanies() {
  if (!state.companies.length) {
    const payload = await api("/api/companies");
    state.companies = payload.companies;
  }
  const list = $("#company-list");
  list.replaceChildren(...state.companies.map((company) => el("button", {
    class: "company-item", type: "button",
    "aria-pressed": String(state.activeCompany === company.ticker),
    onclick: () => { state.activeCompany = company.ticker; loadCompanies(); },
  }, [
    el("span", {}, `${company.ticker} — ${company.name}`),
    el("span", { class: "sub" }, `${company.documents} docs · ${company.sector || "—"}`),
  ])));
  if (!state.activeCompany) state.activeCompany = state.companies[0]?.ticker;
  if (state.activeCompany) renderCompany(state.activeCompany);
}

async function renderCompany(ticker) {
  const detail = $("#company-detail");
  spinner(detail, `Loading ${ticker}…`);
  try {
    const [profile, chartSvg] = await Promise.all([
      api(`/api/companies/${ticker}`),
      api(`/api/companies/${ticker}/charts`),
    ]);
    const metrics = profile.metrics || {};
    // Multiples on the valuation basis (LTM when a 10-Q allowed one), labelled,
    // with the forward multiple beside them: a multiple without its period is
    // the kind of number an audit sends back.
    const basis = metrics.valuation_basis || metrics.latest_actual || {};
    const basisLabel = metrics.basis_label || `FY${basis.fiscal_year || ""}`;
    const ntm = metrics.ntm || null;
    const bridge = metrics.ev_bridge || {};
    const evNote = metrics.enterprise_value == null
      ? "EV not bridged: net debt unknown"
      : `EV ${money(metrics.enterprise_value, metrics.currency)}${bridge.balance_sheet_date ? ` · balance sheet ${bridge.balance_sheet_date}` : ""}`;
    const tiles = [
      tile("Share price", price(metrics.share_price, metrics.currency), metrics.as_of ? `as of ${metrics.as_of}` : ""),
      tile("Market cap", money(metrics.market_cap, metrics.currency), evNote),
      tile(`EV / EBITDA (${basisLabel})`, mult(basis.ev_ebitda), `EV/Revenue ${mult(basis.ev_revenue)} · P/E ${mult(basis.pe)}`),
      tile("EBITDA margin", pct(basis.ebitda_margin), basisLabel),
    ];
    if (ntm && ntm.ev_ebitda != null) {
      tiles.push(tile("EV / NTM EBITDA", mult(ntm.ev_ebitda),
        `${ntm.ebitda_derived ? "derived at current margin" : "estimate rows"} · NTM P/E ${mult(ntm.pe)}`));
    }
    tiles.push(tile("Corpus tone", `${profile.sentiment >= 0 ? "+" : ""}${profile.sentiment}`, `${profile.document_count} documents`));
    const shareNote = metrics.shares_basic != null && metrics.shares_diluted !== metrics.shares_basic
      ? `Per-share figures use the diluted weighted average (${num(metrics.shares_diluted, 2)}m); the cover page shows ${num(metrics.shares_basic, 2)}m.`
      : `Per-share figures use the cover-page share count (${num(metrics.shares_diluted, 2)}m).`;
    fill(detail,
      el("div", { class: "panel" }, [
        el("h1", {}, `${profile.name} (${profile.ticker})`),
        el("p", { class: "muted small" }, `${profile.industry || ""} · ${profile.hq || ""} · ${num(profile.employees)} employees`),
        el("p", {}, profile.description),
        el("div", { class: "tiles" }, tiles),
        el("p", { class: "muted small" }, [shareNote, metrics.debt_note ? ` ${metrics.debt_note}` : ""].join("")),
      ]),
      el("div", { class: "panel-grid" }, [
        el("div", { class: "panel" }, el("div", { class: "chart-slot", html: chartSvg.revenue })),
        el("div", { class: "panel" }, el("div", { class: "chart-slot", html: chartSvg.margin })),
      ]),
      el("div", { class: "panel-grid" }, [
        el("div", { class: "panel" }, el("div", { class: "chart-slot", html: chartSvg.sentiment })),
        el("div", { class: "panel" }, el("div", { class: "chart-slot", html: chartSvg.volume })),
      ]),
      el("div", { class: "panel-grid" }, [
        el("div", { class: "panel" }, [
          el("h2", {}, "Metrics extracted from the corpus"),
          profile.kpis?.length
            ? dataTable([
              { key: "label", label: "Metric" },
              { key: "latest", label: "Latest", numeric: true, render: (v, row) => v === null ? "n/a" : `${num(v, 1)}${row.unit === "%" ? "%" : ""}` },
              { key: "observations", label: "Obs.", numeric: true },
            ], profile.kpis)
            : el("p", { class: "empty" }, "No metrics parsed yet."),
        ]),
        el("div", { class: "panel" }, [
          el("h2", {}, "Themes in recent disclosure"),
          el("div", { class: "examples" }, (profile.themes || []).map((theme) => el("button", {
            class: "chip", type: "button",
            onclick: () => { $("#q").value = `"${theme.theme}" ticker:${profile.ticker}`; setRoute("research"); runSearch(); },
          }, `${theme.theme} · ${theme.lift}x`))),
        ]),
      ]),
      el("div", { class: "panel" }, [
        el("h2", {}, "Financials"),
        dataTable([
          { key: "fiscal_year", label: "FY", render: (v, row) => `FY${v}${row.is_estimate ? "E" : ""}` },
          { key: "revenue", label: "Revenue", numeric: true, render: (v) => num(v) },
          { key: "ebitda", label: "EBITDA", numeric: true, render: (v) => num(v) },
          { key: "ebit", label: "EBIT", numeric: true, render: (v) => num(v) },
          { key: "net_income", label: "Net income", numeric: true, render: (v) => num(v) },
          { key: "eps", label: "EPS", numeric: true, render: (v) => num(v, 2) },
          { key: "capex", label: "Capex", numeric: true, render: (v) => num(v) },
        ], profile.financials || []),
      ]),
      el("div", { class: "panel" }, [
        el("h2", {}, "Documents"),
        ...(profile.documents || []).map(documentCard),
      ]),
      el("div", { class: "panel" }, [
        el("h2", {}, "Build a pitch book on this name"),
        el("button", {
          class: "primary", type: "button",
          onclick: async () => {
            try {
              const book = await api("/api/pitchbooks", {
                method: "POST",
                body: { target_ticker: profile.ticker, title: `Project ${profile.name.split(" ")[0]}` },
              });
              state.pitchbooks = [];
              state.activeBook = book.id;
              toast(`Deck generated: ${book.title}`);
              setRoute("pitchbooks");
            } catch (error) { toast(error.message); }
          },
        }, `Generate deck for ${profile.ticker}`),
      ]),
    );
  } catch (error) {
    detail.replaceChildren(el("p", { class: "empty" }, `Could not load company: ${error.message}`));
  }
}

/* ----------------------------------------------------------- pitch books */

async function loadPitchbooks() {
  if (!state.companies.length) {
    state.companies = (await api("/api/companies")).companies;
  }
  const targetSelect = $("#book-target");
  if (!targetSelect.childElementCount) {
    targetSelect.replaceChildren(...state.companies.map((company) =>
      el("option", { value: company.ticker }, `${company.ticker} — ${company.name}`)));
    renderCompPicker();
    targetSelect.addEventListener("change", renderCompPicker);
  }
  const payload = await api("/api/pitchbooks");
  state.pitchbooks = payload.pitchbooks;
  state.exportFormats = payload.export_formats;
  const index = $("#book-index");
  if (!state.pitchbooks.length) {
    index.replaceChildren(el("p", { class: "empty" }, "No decks yet. Generate one from a target company."));
  } else {
    index.replaceChildren(...state.pitchbooks.map((book) => el("button", {
      class: "book-item", type: "button", "aria-pressed": String(state.activeBook === book.id),
      onclick: () => { state.activeBook = book.id; loadPitchbooks(); },
    }, [
      el("span", {}, book.title),
      el("span", { class: "sub" },
        `${book.ticker || "—"} · ${book.slide_count} slides · ${book.evidence_count} evidence · ${String(book.updated_at).slice(0, 10)}`),
    ])));
  }
  if (!state.activeBook && state.pitchbooks.length) state.activeBook = state.pitchbooks[0].id;
  if (state.activeBook) renderBook(state.activeBook);
  else $("#book-detail").replaceChildren(el("p", { class: "empty" }, "Select or generate a deck."));
}

async function renderCompPicker() {
  const target = $("#book-target").value;
  const picker = $("#book-comps");
  picker.replaceChildren(el("p", { class: "spinner" }, "Suggesting comparables…"));
  try {
    const payload = await api(`/api/companies/${target}/suggest-comps`);
    const suggested = new Set(payload.comps);
    picker.replaceChildren(...state.companies
      .filter((company) => company.ticker !== target)
      .map((company) => el("button", {
        class: "chip", type: "button", "aria-pressed": String(suggested.has(company.ticker)),
        dataset: { ticker: company.ticker },
        onclick: (event) => {
          const node = event.currentTarget;
          node.setAttribute("aria-pressed", node.getAttribute("aria-pressed") === "true" ? "false" : "true");
        },
      }, company.ticker)));
  } catch (error) {
    picker.replaceChildren(el("p", { class: "empty" }, error.message));
  }
}

async function renderBook(bookId) {
  const detail = $("#book-detail");
  spinner(detail, "Rendering deck…");
  try {
    const [book, preview] = await Promise.all([
      api(`/api/pitchbooks/${bookId}`),
      api(`/api/pitchbooks/${bookId}/preview`),
    ]);
    const assumptions = book.slides.find((slide) => slide.kind === "dcf")?.payload?.assumptions || {};
    fill(detail,
      el("div", { class: "panel" }, [
        el("div", { class: "book-toolbar" }, [
          el("strong", {}, book.title),
          el("span", { class: "pill ticker" }, book.ticker || "—"),
          el("span", { class: "muted small" }, `${book.slides.length} slides · ${book.evidence.length} pinned items · comps ${book.comps.join(", ") || "none"}`),
          el("span", { class: "spacer" }),
          ...Object.entries(state.exportFormats).filter(([, ok]) => ok).map(([format]) => el("a", {
            class: "ghost", style: "text-decoration:none",
            href: `/api/pitchbooks/${bookId}/export?format=${format}`,
          }, `Export ${format.toUpperCase()}`)),
          el("button", {
            class: "ghost", type: "button",
            onclick: async () => { await api(`/api/pitchbooks/${bookId}/rebuild`, { method: "POST" }); toast("Deck rebuilt from current data"); renderBook(bookId); },
          }, "Rebuild"),
          el("button", {
            class: "ghost", type: "button",
            onclick: async () => {
              if (!confirm(`Delete “${book.title}”?`)) return;
              await api(`/api/pitchbooks/${bookId}`, { method: "DELETE" });
              state.activeBook = null;
              toast("Deck deleted");
              loadPitchbooks();
            },
          }, "Delete"),
        ]),
        el("details", {}, [
          el("summary", { class: "small muted" }, "DCF assumptions — edit and rebuild"),
          el("form", {
            class: "assumptions", style: "margin-top:10px",
            onsubmit: async (event) => {
              event.preventDefault();
              const body = {};
              $$("input[data-assumption]", event.currentTarget).forEach((input) => {
                if (input.value !== "") body[input.dataset.assumption] = Number(input.value);
              });
              await api(`/api/pitchbooks/${bookId}/assumptions`, { method: "POST", body });
              toast("Assumptions applied; valuation slides rebuilt");
              renderBook(bookId);
            },
          }, [
            ...[
              ["wacc", "WACC (decimal)", assumptions.wacc],
              ["terminal_growth", "Terminal growth", assumptions.terminal_growth],
              ["revenue_growth", "Revenue growth yr 1", assumptions.revenue_growth],
              ["ebitda_margin", "EBITDA margin", assumptions.ebitda_margin],
              ["capex_pct_revenue", "Capex % revenue", assumptions.capex_pct_revenue],
              ["tax_rate", "Tax rate", assumptions.tax_rate],
              ["exit_multiple", "Exit multiple (optional)", assumptions.exit_multiple],
              ["years", "Projection years", assumptions.years],
            ].map(([key, label, value]) => el("label", {}, [
              label,
              el("input", { type: "number", step: "any", value: value ?? "", dataset: { assumption: key } }),
            ])),
            el("div", {}, el("button", { class: "primary", type: "submit" }, "Apply assumptions")),
          ]),
        ]),
      ]),
      el("div", { class: "deck-preview", html: preview.html }),
    );
  } catch (error) {
    detail.replaceChildren(el("p", { class: "empty" }, `Could not render deck: ${error.message}`));
  }
}

/* ---------------------------------------------------------------- monitor */

async function loadMonitor() {
  const [alerts, saved, watchlists] = await Promise.all([
    api("/api/alerts"), api("/api/saved-searches"), api("/api/watchlists"),
  ]);
  const alertsNode = $("#alerts");
  const live = alerts.alerts.filter((alert) => alert.new_documents > 0);
  fill(alertsNode,
    ...(alerts.alerts.length
      ? (live.length
        ? live.map((alert) => el("div", { class: "panel" }, [
          el("h3", {}, `${alert.name} — ${alert.new_documents} new`),
          ...alert.hits.slice(0, 4).map(documentCard),
        ]))
        : [el("p", { class: "empty" }, "No new documents match your saved searches.")])
      : [el("p", { class: "empty" }, "Save a search from the Research tab to start monitoring it.")]),
  );
  fill($("#saved-searches"),
    ...(saved.saved_searches.length
      ? saved.saved_searches.map((row) => el("div", { class: "row" }, [
        el("button", {
          class: "company-item", type: "button",
          onclick: () => { $("#q").value = row.query; setRoute("research"); runSearch(); },
        }, [el("span", {}, row.name), el("span", { class: "sub" }, row.query)]),
        el("button", {
          class: "ghost small", type: "button",
          onclick: async () => { await api(`/api/saved-searches/${row.id}`, { method: "DELETE" }); loadMonitor(); },
        }, "Remove"),
      ]))
      : [el("p", { class: "empty" }, "Nothing saved yet.")]),
  );
  fill($("#watchlists"),
    ...(watchlists.watchlists.length
      ? watchlists.watchlists.map((list) => el("div", { class: "panel" }, [
        el("div", { class: "book-toolbar" }, [
          el("strong", {}, list.name),
          el("span", { class: "spacer" }),
          el("button", {
            class: "ghost small", type: "button",
            onclick: async () => { await api(`/api/watchlists/${list.id}`, { method: "DELETE" }); loadMonitor(); },
          }, "Delete list"),
        ]),
        list.companies.length
          ? dataTable([
            { key: "ticker", label: "Ticker" },
            { key: "name", label: "Company" },
            { key: "sentiment", label: "Tone", numeric: true, render: (v) => v === null ? "n/a" : `${v >= 0 ? "+" : ""}${Number(v).toFixed(2)}` },
            { key: "latest", label: "Latest document" },
          ], list.companies, (row) => { state.activeCompany = row.ticker; setRoute("companies"); })
          : el("p", { class: "empty" }, "Empty list."),
        el("form", {
          class: "row", style: "margin-top:10px",
          onsubmit: async (event) => {
            event.preventDefault();
            const select = $("select", event.currentTarget);
            await api(`/api/watchlists/${list.id}/items`, { method: "POST", body: { ticker: select.value } });
            loadMonitor();
          },
        }, [
          el("select", { "aria-label": `Add a company to ${list.name}` },
            state.companies.map((company) => el("option", { value: company.ticker }, `${company.ticker} — ${company.name}`))),
          el("button", { class: "ghost", type: "submit" }, "Add"),
        ]),
      ]))
      : [el("p", { class: "empty" }, "No watchlists yet.")]),
  );
}

/* ------------------------------------------------------------ pin dialog */

async function openPinDialog(target) {
  state.pinTarget = target;
  if (!state.pitchbooks.length) {
    state.pitchbooks = (await api("/api/pitchbooks")).pitchbooks;
  }
  if (!state.pitchbooks.length) {
    toast("Generate a pitch book first, then pin evidence to it.");
    return;
  }
  $("#pin-quote").textContent = target.quote;
  $("#pin-book").replaceChildren(...state.pitchbooks.map((book) =>
    el("option", { value: book.id }, `${book.title} (${book.ticker || "—"})`)));
  $("#pin-note").value = "";
  $("#pin-dialog").showModal();
}

async function renderExamples() {
  let first = null;
  try {
    if (!state.companies.length) state.companies = (await api("/api/companies")).companies;
    first = state.companies[0]?.ticker || null;
  } catch (error) { /* examples are a convenience; the search box works without them */ }
  $("#examples").replaceChildren(...exampleQueries(first).map((query) => el("button", {
    class: "chip", type: "button",
    onclick: () => { $("#q").value = query; runSearch(); },
  }, query)));
}

/* ------------------------------------------------------------------ boot */

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("argos-theme", theme);
}

function initTheme() {
  const stored = localStorage.getItem("argos-theme");
  if (stored) document.documentElement.dataset.theme = stored;
  $("#theme-toggle").addEventListener("click", () => {
    const current = document.documentElement.dataset.theme
      || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    applyTheme(current === "dark" ? "light" : "dark");
  });
}

function init() {
  initTheme();
  $$(".tab").forEach((tab) => tab.addEventListener("click", () => setRoute(tab.dataset.route)));
  $("#search-form").addEventListener("submit", (event) => { event.preventDefault(); runSearch(); });
  renderExamples();
  $("#save-search").addEventListener("click", async () => {
    if (!state.query) { toast("Type a query first."); return; }
    await api("/api/saved-searches", {
      method: "POST",
      body: { name: state.query, query: state.query, filters: state.filters },
    });
    toast("Saved. New matches will appear under Monitor.");
  });
  $("#book-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const comps = $$("#book-comps .chip[aria-pressed='true']").map((chip) => chip.dataset.ticker);
    try {
      const book = await api("/api/pitchbooks", {
        method: "POST",
        body: {
          target_ticker: $("#book-target").value,
          title: $("#book-title").value || undefined,
          client_name: $("#book-client").value || undefined,
          banker: $("#book-banker").value || undefined,
          comp_tickers: comps.length ? comps : undefined,
        },
      });
      state.activeBook = book.id;
      toast(`Generated ${book.slides.length} slides`);
      loadPitchbooks();
    } catch (error) { toast(error.message); }
  });
  $("#watchlist-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = $("#watchlist-name").value.trim();
    if (!name) return;
    await api("/api/watchlists", { method: "POST", body: { name } });
    $("#watchlist-name").value = "";
    loadMonitor();
  });
  $("#pin-form").addEventListener("submit", async (event) => {
    if (event.submitter?.value !== "pin") return;
    const target = state.pinTarget;
    if (!target) return;
    try {
      await api(`/api/pitchbooks/${$("#pin-book").value}/evidence`, {
        method: "POST",
        body: { quote: target.quote, document_id: target.document_id, chunk_id: target.chunk_id, note: $("#pin-note").value || undefined },
      });
      toast("Pinned to the deck appendix.");
      if (state.activeBook) renderBook(state.activeBook);
    } catch (error) { toast(error.message); }
  });
  window.addEventListener("hashchange", () => setRoute(location.hash.slice(1) || "dashboard"));
  setRoute(location.hash.slice(1) || "dashboard");
}

init();
