# frozen_string_literal: true

module Seed
  # Deterministic demo dataset.
  #
  # Every company, filing, transcript and broker note below is fictional and
  # generated locally from a fixed seed. It exists so the research index, the
  # comps screen and the valuation models have something real-shaped to chew on
  # out of the box; swap it for your own corpus with `argos:ingest[path]`.
  #
  # The generator deliberately builds a *narrative arc* across periods — grid
  # interconnection backlogs and datacenter load growth become dominant themes
  # late in the window while pricing pressure builds — so trending-theme
  # detection and sentiment timelines have signal to find rather than noise.
  #
  # Port of argos/seed.py. The sentence banks keep Python's `{name:spec}`
  # placeholders verbatim (see `fill`), so the generated text has exactly the
  # shape the KPI patterns and the sentiment lexicon were tuned on. Ruby's
  # Random does not reproduce Python's Mersenne-Twister draws, so the corpus is
  # deterministic for a given seed but its numbers differ from the Python build.
  module Demo
    SECTOR = "Grid & Energy Software"

    COMPANIES = [
      {
        ticker: "NVG", name: "NovaGrid Systems", industry: "Grid orchestration software",
        country: "United States", hq: "Austin, TX", employees: 4280,
        description: "NovaGrid Systems sells a cloud platform that utilities and large industrial " \
                     "consumers use to forecast load, schedule distributed energy resources and " \
                     "settle wholesale market positions. Roughly 78% of revenue is recurring " \
                     "subscription, with the balance in implementation services.",
        fin: { revenue: 1840.0, growth: 0.168, ebitda_margin: 0.262, da_pct: 0.052,
               capex_pct: 0.041, shares: 182.0, net_debt: 410.0,
               ev_ebitda_target: 17.5, beta: 1.21 },
        tone: 0.55
      },
      {
        ticker: "HLDX", name: "Helio Dynamics", industry: "DER management software",
        country: "United States", hq: "San Jose, CA", employees: 3110,
        description: "Helio Dynamics provides distributed energy resource management and virtual power plant software to investor-owned utilities.",
        fin: { revenue: 1320.0, growth: 0.142, ebitda_margin: 0.238, da_pct: 0.049,
               capex_pct: 0.038, shares: 141.0, net_debt: 260.0,
               ev_ebitda_target: 16.0, beta: 1.14 },
        tone: 0.35
      },
      {
        ticker: "VLTR", name: "Voltara Networks", industry: "Grid telemetry & analytics",
        country: "United States", hq: "Denver, CO", employees: 5640,
        description: "Voltara Networks combines grid-edge sensors with an analytics suite for outage prediction and asset health.",
        fin: { revenue: 2410.0, growth: 0.096, ebitda_margin: 0.281, da_pct: 0.061,
               capex_pct: 0.058, shares: 238.0, net_debt: 980.0,
               ev_ebitda_target: 14.5, beta: 1.02 },
        tone: 0.15
      },
      {
        ticker: "CRGD", name: "Cerulean Grid", industry: "Market settlement software",
        country: "United Kingdom", hq: "London, UK", employees: 1980,
        description: "Cerulean Grid runs trading, scheduling and settlement systems for European balancing markets.",
        fin: { revenue: 860.0, growth: 0.201, ebitda_margin: 0.221, da_pct: 0.044,
               capex_pct: 0.036, shares: 96.0, net_debt: 95.0,
               ev_ebitda_target: 18.5, beta: 1.33 },
        tone: 0.60
      },
      {
        ticker: "PYLN", name: "Pylon Analytics", industry: "Transmission planning software",
        country: "United States", hq: "Pittsburgh, PA", employees: 1240,
        description: "Pylon Analytics licenses transmission planning, interconnection study and congestion modelling tools.",
        fin: { revenue: 520.0, growth: 0.247, ebitda_margin: 0.184, da_pct: 0.040,
               capex_pct: 0.033, shares: 71.0, net_debt: -60.0,
               ev_ebitda_target: 20.0, beta: 1.42 },
        tone: 0.70
      },
      {
        ticker: "TWSW", name: "Terrawatt Software", industry: "Renewables asset management",
        country: "Germany", hq: "Munich, DE", employees: 2870,
        description: "Terrawatt Software manages renewable generation fleets, PPAs and curtailment optimisation for IPPs.",
        fin: { revenue: 1150.0, growth: 0.071, ebitda_margin: 0.196, da_pct: 0.055,
               capex_pct: 0.047, shares: 128.0, net_debt: 520.0,
               ev_ebitda_target: 11.5, beta: 1.09 },
        tone: -0.30
      },
      {
        ticker: "MFCL", name: "Meridian Flow Controls", industry: "Industrial control software",
        country: "United States", hq: "Milwaukee, WI", employees: 7320,
        description: "Meridian Flow Controls sells SCADA and control software bundled with legacy hardware service contracts.",
        fin: { revenue: 3080.0, growth: 0.034, ebitda_margin: 0.173, da_pct: 0.068,
               capex_pct: 0.062, shares: 311.0, net_debt: 1640.0,
               ev_ebitda_target: 9.0, beta: 0.91 },
        tone: -0.45
      }
    ].each { |spec| spec[:fin].freeze }.map(&:freeze).freeze

    TRANSACTIONS = [
      { announced_on: Date.new(2026, 6, 18), target: "Arclight Grid Software", acquirer: "Siemens-adjacent strategic",
        sector: SECTOR, ev: 4100.0, ev_revenue: 6.4, ev_ebitda: 22.8, premium_1day: 0.31,
        consideration: "Cash", note: "Full-cash take-private of a subscription-heavy grid planning vendor." },
      { announced_on: Date.new(2026, 2, 4), target: "Keystone DERMS", acquirer: "Thoma-style sponsor",
        sector: SECTOR, ev: 2250.0, ev_revenue: 5.1, ev_ebitda: 19.4, premium_1day: 0.27,
        consideration: "Cash", note: "Sponsor LBO; carve-out of services backlog pre-close." },
      { announced_on: Date.new(2025, 11, 12), target: "Lumen Flow Systems", acquirer: "Strategic acquirer (industrial)",
        sector: SECTOR, ev: 1480.0, ev_revenue: 4.2, ev_ebitda: 16.1, premium_1day: 0.22,
        consideration: "Cash and stock", note: "Hardware-weighted mix drove a lower multiple." },
      { announced_on: Date.new(2025, 7, 29), target: "Meridian Analytics (division)", acquirer: "Private equity consortium",
        sector: SECTOR, ev: 910.0, ev_revenue: 3.6, ev_ebitda: 14.2, premium_1day: 0.18,
        consideration: "Cash", note: "Divisional carve-out with TSA; limited competitive tension." },
      { announced_on: Date.new(2025, 3, 20), target: "Quanta Settlement Co", acquirer: "Exchange operator",
        sector: SECTOR, ev: 3350.0, ev_revenue: 7.1, ev_ebitda: 24.6, premium_1day: 0.38,
        consideration: "Stock", note: "Scarcity premium for regulated settlement infrastructure." },
      { announced_on: Date.new(2024, 10, 8), target: "Northwind Interconnect", acquirer: "Strategic acquirer (software)",
        sector: SECTOR, ev: 1720.0, ev_revenue: 5.6, ev_ebitda: 20.1, premium_1day: 0.29,
        consideration: "Cash", note: "Two-bidder process; synergies underwritten at 7% of target revenue." }
    ].map(&:freeze).freeze

    PERIODS = [
      ["FY24 Q3", Date.new(2024, 10, 24)], ["FY24 Q4", Date.new(2025, 1, 30)],
      ["FY25 Q1", Date.new(2025, 4, 24)], ["FY25 Q2", Date.new(2025, 7, 24)],
      ["FY25 Q3", Date.new(2025, 10, 23)], ["FY25 Q4", Date.new(2026, 1, 29)],
      ["FY26 Q1", Date.new(2026, 4, 23)], ["FY26 Q2", Date.new(2026, 7, 23)]
    ].map(&:freeze).freeze

    # Fiscal years covered by the financial series: three actuals around the
    # base year and three estimates after it.
    YEARS = [2023, 2024, 2025, 2026, 2027, 2028].freeze
    # The market snapshot every demo company is priced as of.
    MARKET_AS_OF = Date.new(2026, 10, 9)
    # The annual report every company files (published the following February).
    FILING_YEAR = 2025

    # Theme pressure by period index: late periods lean on interconnection backlog,
    # datacenter load growth and tariff pass-through.
    EARLY_THEMES = [
      "storm hardening programmes", "meter data management migrations",
      "regulatory rate case timing", "legacy SCADA replacement cycles"
    ].freeze
    LATE_THEMES = [
      "interconnection queue backlog", "datacenter load growth",
      "tariff pass-through on imported hardware", "transmission constraint pricing"
    ].freeze

    POSITIVE_SENTENCES = [
      "Revenue grew {growth:.1f}% year over year, ahead of the guidance range we set last quarter.",
      "Subscription net dollar retention was {ndr:.0f}%, with expansion concentrated in our largest utility accounts.",
      "Adjusted EBITDA margin reached {margin:.1f}%, an improvement of {bps:.0f} basis points, on pricing discipline and lower cloud unit costs.",
      "Bookings momentum was strong across {theme}, and we exited the quarter with backlog of ${backlog:.0f} million.",
      "We are raising our full-year outlook on the strength of the pipeline we see in {theme}.",
      "Free cash flow was ${fcf:.0f} million, and we repurchased shares opportunistically during the quarter.",
      "Gross margin reached {gm:.1f}% as more of the mix shifted toward platform subscriptions."
    ].freeze
    NEUTRAL_SENTENCES = [
      "We closed {wins} new platform agreements in the quarter, weighted toward North American investor-owned utilities.",
      "Implementation timelines remain tied to customer rate case calendars, which we model conservatively.",
      "Headcount ended the period at {headcount} employees, broadly flat sequentially.",
      "Capex was {capex:.1f}% of revenue, consistent with our prior commentary.",
      "Our product roadmap this year centres on {theme} and on deeper integration with market settlement systems.",
      "We continue to evaluate tuck-in acquisitions that add engineering capacity in {theme}."
    ].freeze
    NEGATIVE_SENTENCES = [
      "Revenue declined {decline:.1f}% as two large deployments slipped out of the quarter.",
      "We saw pricing pressure in competitive renewals, and churn ticked up to {churn:.1f}%.",
      "Adjusted EBITDA margin compressed to {margin:.1f}% on higher services mix and cloud cost inflation.",
      "Guidance assumes continued softness in {theme}, and we have taken a cautious view of second-half bookings.",
      "The macro environment remains uncertain, and procurement cycles have lengthened materially.",
      "A restructuring charge of ${charge:.0f} million was recorded as we consolidated delivery centres.",
      "Deceleration in new logo activity was the main driver of the shortfall versus consensus."
    ].freeze
    ANALYST_QUESTIONS = [
      "Can you unpack the margin trajectory from here, and how much of the improvement is durable versus timing?",
      "How should we think about the pipeline conversion in {theme} over the next two quarters?",
      "What are you assuming for pricing in competitive renewals, and where is churn running?",
      "Is the services mix a structural headwind to gross margin, or does it normalise as deployments mature?",
      "Could you size the revenue opportunity tied to {theme}?"
    ].freeze
    RESEARCH_VIEWS = [
      ["Overweight", "We raise our target on {name} as subscription mix and pricing discipline underwrite a durable " \
                     "margin expansion path. Our model assumes {growth:.1f}% revenue growth and {margin:.1f}% EBITDA " \
                     "margin, supported by {theme}. Risks are concentrated in deployment timing."],
      ["Neutral", "We stay sidelined on {name}. The {theme} narrative is real but already discounted at {mult:.1f}x " \
                  "forward EBITDA, and services mix keeps gross margin range-bound. We would revisit on evidence of " \
                  "net retention above 112%."],
      ["Underweight", "We downgrade {name}. Pricing pressure in competitive renewals and an elongating sales cycle " \
                      "point to decelerating bookings, and consensus margin assumptions of {margin:.1f}% look " \
                      "optimistic given cloud cost inflation and a weaker mix in {theme}."]
    ].map(&:freeze).freeze
    NEWS_HEADLINES = [
      ["{name} wins multi-year grid orchestration contract",
       "A top-ten investor-owned utility selected {name} to run load forecasting and DER scheduling across its service territory. The award covers {years} years and is expected to be accretive to backlog."],
      ["{name} flags longer procurement cycles",
       "Management told investors that utility procurement cycles have lengthened, citing regulatory calendars and tariff uncertainty on imported hardware. Shares traded lower on the commentary."],
      ["{name} expands {theme} product line",
       "The company launched a module targeting {theme}, pricing it as a platform upgrade rather than a standalone product."],
      ["{name} named in sector consolidation chatter",
       "Bankers covering {sector} pointed to {name} as a plausible participant in further consolidation after recent take-private activity in the space."]
    ].map(&:freeze).freeze
    FILING_RISK_FACTORS = [
      "Our revenue is concentrated among regulated utilities whose spending is subject to rate case outcomes and commission approval timing.",
      "A meaningful portion of our contracts include annual price escalators tied to published indices; a sustained decline in those indices would reduce realised pricing.",
      "We depend on third-party cloud infrastructure providers, and cost inflation in those services may compress gross margin.",
      "Interconnection queue backlogs and permitting delays may defer customer projects and therefore our implementation revenue.",
      "Tariffs on imported sensing and metering hardware could increase the cost of bundled deployments and pressure margins.",
      "We face competition from larger industrial automation vendors that bundle control software with hardware service contracts."
    ].freeze

    # Python str.format placeholder: `{name}` or `{name:.1f}`.
    PLACEHOLDER_RE = /\{(\w+)(?::([^}]*))?\}/

    module_function

    # Populate companies, financials, market data, transactions and the corpus.
    #
    # Re-running is safe: companies are upserted, their financial and market
    # rows replaced, precedent transactions only inserted into an empty table
    # and documents skipped by `external_id` (which the fixed seed makes stable).
    def seed!(rng_seed: 20261012)
      rng = Random.new(rng_seed)
      company_ids = {}
      specs = COMPANIES.map { |spec| spec.merge(fin: spec[:fin].merge(derive_market(spec, rng))) }

      ActiveRecord::Base.transaction do
        # schema.rb cannot express the FTS table or its triggers, so a database
        # built by db:schema:load would otherwise index nothing we ingest here.
        SearchIndex.ensure!

        specs.each do |spec|
          company = Company.upsert_by_ticker!(
            ticker: spec[:ticker], name: spec[:name], sector: SECTOR,
            industry: spec[:industry], country: spec[:country], hq: spec[:hq],
            employees: spec[:employees], currency: "USD", description: spec[:description]
          )
          company_ids[spec[:ticker]] = company.id
          company.financials.delete_all
          financial_series(spec[:fin], YEARS).each { |row| company.financials.create!(row) }
          fin = spec[:fin]
          MarketDatum.where(company_id: company.id).delete_all
          MarketDatum.create!(
            company_id: company.id, as_of: MARKET_AS_OF, share_price: fin[:price],
            shares_diluted: fin[:shares], net_debt: fin[:net_debt],
            week52_low: fin[:low], week52_high: fin[:high], beta: fin[:beta]
          )
        end

        TRANSACTIONS.each { |deal| Transaction.create!(deal) } unless Transaction.exists?

        documents = []
        specs.each do |spec|
          base_tone = spec[:tone]
          PERIODS.each_with_index do |(period, when_), idx|
            late = idx >= PERIODS.size - 3
            theme = (late ? LATE_THEMES : EARLY_THEMES).sample(random: rng)
            # Tone decays slightly over the window for everyone (pricing pressure)
            # and is jittered per quarter so sentiment timelines are not flat.
            tone = (base_tone - 0.07 * idx + rng.rand(-0.18..0.18)).clamp(-1.0, 1.0)
            documents << transcript(rng, spec, period, when_, theme, tone)
            documents << research_note(rng, spec, when_ + 2, theme, tone) if idx % 2 == 0
            documents << news(rng, spec, when_ + rng.rand(6..40), theme) if idx % 3 == 1
          end
          documents << filing(spec, FILING_YEAR, Date.new(FILING_YEAR + 1, 2, 14))
        end

        [[Date.new(2026, 3, 5), LATE_THEMES[0]], [Date.new(2026, 6, 11), LATE_THEMES[1]],
         [Date.new(2025, 9, 17), EARLY_THEMES[0]], [Date.new(2026, 8, 28), LATE_THEMES[2]]].each do |when_, theme|
          documents << expert_call(rng, when_, theme)
        end

        result = Ingest.ingest_many(documents)
        {
          companies: company_ids.size,
          transactions: Transaction.count,
          documents_added: result[:added],
          documents_skipped: result[:skipped],
          chunks: Chunk.count,
          kpis: Kpi.count
        }
      end
    end

    # Derive share price and 52-week range from a target EV/EBITDA multiple.
    #
    # Pricing the demo set off a multiple (rather than hardcoding share prices)
    # keeps the comps screen internally consistent: implied multiples land where
    # the quality spread says they should, instead of wherever a made-up price
    # happened to fall.
    def derive_market(spec, rng)
      fin = spec[:fin]
      ebitda = fin[:revenue] * fin[:ebitda_margin]
      enterprise_value = fin[:ev_ebitda_target] * ebitda
      price = [1.0, (enterprise_value - fin[:net_debt]) / fin[:shares]].max
      {
        price: price.round(2),
        low: (price * rng.rand(0.68..0.78)).round(2),
        high: (price * rng.rand(1.04..1.18)).round(2)
      }
    end

    # "FY26 Q2" -> 2026. (Unused by the generator, as in the reference.)
    def fy_from_period(period)
      2000 + period[2, 2].to_i
    end

    # Back-cast and forecast a simple financial series around the base year.
    def financial_series(spec, years)
      base_year = years[years.size / 2]
      years.map do |year|
        drift = spec[:growth] * (year > base_year ? 0.82 : 1.0)
        factor = (1 + drift)**(year - base_year)
        revenue = spec[:revenue] * factor
        margin = spec[:ebitda_margin] + 0.004 * (year - base_year)
        ebitda = revenue * margin
        dep_amort = revenue * spec[:da_pct]
        ebit = ebitda - dep_amort
        tax_rate = 0.23
        net_income = [0.0, ebit * (1 - tax_rate)].max - [0.0, spec[:net_debt]].max * 0.045 * (1 - tax_rate)
        {
          fiscal_year: year,
          is_estimate: year > base_year,
          revenue: revenue.round(1),
          ebitda: ebitda.round(1),
          ebit: ebit.round(1),
          net_income: net_income.round(1),
          eps: (net_income / spec[:shares]).round(2),
          dep_amort: dep_amort.round(1),
          capex: (revenue * spec[:capex_pct]).round(1),
          nwc_change: (revenue * 0.012).round(1),
          tax_rate: tax_rate
        }
      end
    end

    def transcript(rng, spec, period, when_, theme, tone)
      fin = spec[:fin]
      numbers = {
        growth: [1.0, fin[:growth] * 100 + rng.rand(-3.5..3.5)].max,
        decline: rng.rand(1.5..7.5).abs,
        ndr: 100 + tone * 14 + rng.rand(-3.0..5.0),
        margin: fin[:ebitda_margin] * 100 + tone * 2.2 + rng.rand(-1.5..1.5),
        bps: tone.abs * 180 + rng.rand(20.0..120.0),
        gm: 62 + tone * 6 + rng.rand(-2.0..3.0),
        backlog: fin[:revenue] * rng.rand(0.55..0.95),
        fcf: fin[:revenue] * fin[:ebitda_margin] * rng.rand(0.45..0.75),
        churn: 4.5 - tone * 1.6 + rng.rand(-0.6..0.9),
        wins: rng.rand(4..23),
        headcount: spec[:employees] + rng.rand(-220..320),
        capex: fin[:capex_pct] * 100 + rng.rand(-0.6..0.8),
        charge: fin[:revenue] * rng.rand(0.01..0.035),
        theme: theme,
        name: spec[:name]
      }

      pick = ->(bank, count) { bank.sample([count, bank.size].min, random: rng).map { |s| fill(s, numbers) } }

      if tone > 0.2
        ceo_lines = pick.call(POSITIVE_SENTENCES, 3) + pick.call(NEUTRAL_SENTENCES, 1)
        cfo_lines = pick.call(POSITIVE_SENTENCES, 2) + pick.call(NEUTRAL_SENTENCES, 2)
      elsif tone < -0.2
        ceo_lines = pick.call(NEGATIVE_SENTENCES, 3) + pick.call(NEUTRAL_SENTENCES, 1)
        cfo_lines = pick.call(NEGATIVE_SENTENCES, 2) + pick.call(NEUTRAL_SENTENCES, 2)
      else
        ceo_lines = pick.call(NEUTRAL_SENTENCES, 2) + pick.call(POSITIVE_SENTENCES, 1) + pick.call(NEGATIVE_SENTENCES, 1)
        cfo_lines = pick.call(NEUTRAL_SENTENCES, 2) + pick.call(POSITIVE_SENTENCES, 1)
      end

      question = fill(ANALYST_QUESTIONS.sample(random: rng), numbers)
      answer = pick.call(tone >= 0 ? POSITIVE_SENTENCES : NEGATIVE_SENTENCES, 2).join(" ")
      body = [
        "Operator: Good morning, and welcome to the " \
        "#{spec[:name]} #{period} earnings conference call. All participants are in listen-only mode.",
        "Avery Lin, Chief Executive Officer: Thanks, everyone, for joining. #{ceo_lines.join(' ')}",
        "Dana Okafor, Chief Financial Officer: Turning to the financials. #{cfo_lines.join(' ')} " \
        "For the full year we now expect revenue growth in the #{format('%.0f', numbers[:growth] - 1.5)} to " \
        "#{format('%.0f', numbers[:growth] + 1.5)}% range.",
        "Priya Raman, Analyst, Northbank Securities: #{question}",
        "Avery Lin, Chief Executive Officer: #{answer}",
        "Dana Okafor, Chief Financial Officer: To add to that, our planning assumption on #{theme} is deliberately " \
        "conservative, and we have not embedded upside from it in the guidance range."
      ].join("\n\n")
      {
        external_id: "#{spec[:ticker]}-#{period.delete(' ')}-call",
        title: "#{spec[:name]} #{period} Earnings Call Transcript",
        ticker: spec[:ticker],
        doc_type: "transcript",
        source: "Company call",
        author: "Investor Relations",
        published_at: when_,
        period: period,
        body: body
      }
    end

    def research_note(rng, spec, when_, theme, tone)
      fin = spec[:fin]
      rating, template = if tone > 0.25 then RESEARCH_VIEWS[0]
                         elsif tone < -0.25 then RESEARCH_VIEWS[2]
                         else RESEARCH_VIEWS[1]
                         end
      numbers = {
        name: spec[:name], theme: theme,
        growth: fin[:growth] * 100 + rng.rand(-2.0..2.0),
        margin: fin[:ebitda_margin] * 100 + rng.rand(-1.5..1.5),
        mult: 12 + tone * 5 + rng.rand(-1.5..2.5)
      }
      body = [
        "Rating: #{rating}. Price target $#{format('%.0f', fin[:price] * (1 + tone * 0.18))}.",
        fill(template, numbers),
        "Valuation. We value #{spec[:name]} on #{format('%.1f', numbers[:mult])}x forward EV/EBITDA, a " \
        "#{tone > 0 ? 'premium' : 'discount'} to the #{SECTOR.downcase} peer median, reflecting subscription mix " \
        "of roughly #{format('%.0f', 60 + tone * 20)}% and net debt of $#{format('%.0f', fin[:net_debt])} million.",
        "What would change our view. Evidence that #{theme} converts to multi-year platform contracts would raise our " \
        "estimates; a second consecutive quarter of pricing pressure in renewals would lower them."
      ].join("\n\n")
      {
        external_id: "#{spec[:ticker]}-research-#{when_.iso8601}",
        title: "#{spec[:name]} (#{spec[:ticker]}): #{rating} — #{title_case(theme)}",
        ticker: spec[:ticker],
        doc_type: "research",
        source: "Northbank Securities",
        author: "P. Raman",
        published_at: when_,
        body: body
      }
    end

    def filing(spec, year, when_)
      fin = spec[:fin]
      body = [
        "Item 1. Business. #{spec[:description]}",
        "Item 7. Management's Discussion and Analysis. Revenue for fiscal #{year} was $#{format('%.0f', fin[:revenue])} million, " \
        "an increase of #{format('%.1f', fin[:growth] * 100)}% over the prior year. Adjusted EBITDA margin was " \
        "#{format('%.1f', fin[:ebitda_margin] * 100)}%. Capex was #{format('%.1f', fin[:capex_pct] * 100)}% of revenue. We ended the year " \
        "with net debt of $#{format('%.0f', fin[:net_debt])} million and #{spec[:employees]} employees.",
        "Item 1A. Risk Factors. #{FILING_RISK_FACTORS.join(' ')}",
        "Item 7A. Quantitative and Qualitative Disclosures About Market Risk. Our reported results are exposed to " \
        "currency movements, principally in EUR and GBP, and to floating-rate interest expense on our revolving " \
        "credit facility."
      ].join("\n\n")
      {
        external_id: "#{spec[:ticker]}-10K-#{year}",
        title: "#{spec[:name]} Annual Report (Form 10-K), FY#{year}",
        ticker: spec[:ticker],
        doc_type: "filing",
        source: "Regulatory filing",
        published_at: when_,
        body: body
      }
    end

    def news(rng, spec, when_, theme)
      headline, template = NEWS_HEADLINES.sample(random: rng)
      fields = { name: spec[:name], theme: theme, sector: SECTOR, years: rng.rand(3..8) }
      fin = spec[:fin]
      {
        external_id: "#{spec[:ticker]}-news-#{when_.iso8601}-#{rng.rand(1000..9999)}",
        title: fill(headline, fields),
        ticker: spec[:ticker],
        doc_type: "news",
        source: "Market wire",
        published_at: when_,
        body: "#{fill(template, fields)}\n\n" \
              "#{spec[:name]} trades at $#{format('%.2f', fin[:price])}, within a 52-week range of " \
              "$#{format('%.2f', fin[:low])} to $#{format('%.2f', fin[:high])}."
      }
    end

    def expert_call(rng, when_, theme)
      body = [
        "Interviewer: You spent eleven years on the procurement side at a large investor-owned utility. How do " \
        "software vendors actually get selected?",
        "Expert: Almost everything flows through the rate case. If the spend is not in an approved plan, it does not " \
        "happen, regardless of the payback. What has changed in the last year is #{theme} — that pressure is now " \
        "showing up as capital plan line items, which pulls software decisions forward.",
        "Interviewer: Where does pricing pressure come from?",
        "Expert: Competitive renewals. The incumbents know the switching cost is high, so list price escalators hold, " \
        "but when an industrial automation vendor bundles control software with a hardware service contract, the " \
        "effective discount can reach twenty percent. That is the real pricing pressure in this market, and it is " \
        "under-appreciated.",
        "Interviewer: Which capability is scarce? Expert: Anyone who can model #{theme} credibly for a regulator. " \
        "That is a small pool of engineers, and it is why tuck-in acquisitions in this space are priced on talent, " \
        "not on revenue."
      ].join("\n\n")
      {
        external_id: "expert-#{when_.iso8601}-#{rng.rand(1000..9999)}",
        title: "Expert Call: Utility Procurement and #{title_case(theme)}",
        doc_type: "expert-call",
        source: "Expert network",
        published_at: when_,
        body: body
      }
    end

    # Python's str.format(**values) for the subset the banks use: `{name}` is
    # str(value), `{name:.1f}` is printf-style. Unused keys are ignored, a
    # missing one raises, exactly as in Python.
    def fill(template, values)
      template.gsub(PLACEHOLDER_RE) do
        value = values.fetch(Regexp.last_match(1).to_sym)
        spec = Regexp.last_match(2)
        spec ? format("%#{spec}", value) : value.to_s
      end
    end

    # Python's str.title(): a cased letter is upcased after an uncased character
    # (space, hyphen, digit) and downcased after another letter, so
    # "tariff pass-through" -> "Tariff Pass-Through" (String#capitalize per
    # space-separated word would leave the "t" after the hyphen lower case).
    def title_case(text)
      prev_cased = false
      text.each_char.map do |char|
        cased = char.match?(/[\p{Lu}\p{Ll}\p{Lt}]/)
        out = if !cased then char
              elsif prev_cased then char.downcase
              else char.upcase
              end
        prev_cased = cased
        out
      end.join
    end

    private_class_method :fy_from_period, :fill, :title_case
  end
end
