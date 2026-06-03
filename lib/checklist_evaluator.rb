require 'time'

# Heuristically evaluates a Salesforce case against the 6-item Engineering
# escalation checklist. Returns green/amber/red verdicts with evidence and
# gap descriptions for each item.
#
# These are signals only — the Copilot agent interviews the engineer to
# confirm or fill gaps before generating the final escalation package.
class ChecklistEvaluator

  PRODUCT_KEYWORDS = {
    'Automate'     => /chef.?automate|\bautomate\b/i,
    'Infra Client' => /\binfra.?client\b|chef.?client|chef-client/i,
    'Infra Server' => /\binfra.?server\b|chef.?server\b/i,
    'Courier'      => /chef.?360|\bcourier\b/i,
    'Habitat'      => /\bhabitat\b/i,
    'Compliance'   => /\binspec\b|compliance/i,
    'Knife'        => /\bknife\b/i,
    'Extensions'   => /\bextension\b/i
  }.freeze

  RED_ACCOUNTS    = (ENV['RED_ACCOUNTS']    || '').split(',').map(&:strip).freeze
  YELLOW_ACCOUNTS = (ENV['YELLOW_ACCOUNTS'] || '').split(',').map(&:strip).freeze

  def self.evaluate(case_data)
    new(case_data).evaluate
  end

  def initialize(case_data)
    @case        = case_data[:case]
    @comments    = case_data[:comments] || []
    @case_number = case_data[:case_number]
    @account     = case_data[:account]
    @corpus      = build_corpus
  end

  def evaluate
    {
      case_summary:  case_summary,
      checklist:     run_checklist,
      additional:    run_additional_checks,
      comment_count: @comments.length,
      last_comment:  @comments.last,
      comments:      @comments,
      pre_populate:  pre_populate_form
    }
  end

  private

  def build_corpus
    parts = [@case['Description'].to_s]
    @comments.each { |c| parts << c['CommentBody'].to_s }
    parts.join("\n\n").downcase
  end

  def case_summary
    arr = @account&.[]('AnnualRevenue')
    renewal_field = ENV.fetch('SF_RENEWAL_DATE_FIELD', 'Contract_End_Date__c')
    renewal = @account&.[](renewal_field)
    {
      case_number:    @case_number,
      subject:        @case['Subject'],
      status:         @case['Status'],
      severity:       @case['Severity__c'],
      support_level:  @case['Chef_Support_Level__c'],
      account:        @case.dig('Account', 'Name'),
      account_arr:    arr,
      account_renewal: renewal,
      contact:        @case.dig('Contact', 'Name'),
      created:        @case['CreatedDate'],
      last_modified:  @case['LastModifiedDate'],
      last_modified_by: @case.dig('LastModifiedBy', 'Name')
    }
  end

  # ── Six required checklist items ────────────────────────────────────────────

  def run_checklist
    [
      check_env_config,
      check_logs,
      check_rca,
      check_workarounds,
      check_reproduce,
      check_ai_used
    ]
  end

  # ── Additional context checks ────────────────────────────────────────────────

  def run_additional_checks
    [
      check_jira_linked,
      check_severity,
      check_account_risk,
      check_customer_updated
    ]
  end

  # 1 — Customer environment & product version
  def check_env_config
    signals = []
    signals << 'OS/platform mentioned'     if @corpus.match?(/\b(ubuntu|rhel|centos|debian|windows|amazon linux|suse|rocky|alma)\b/)
    signals << 'version number present'    if @corpus.match?(/\bv?\d+\.\d+(\.\d+)?\b/)
    signals << 'hardware/capacity noted'   if @corpus.match?(/\b(cpu|cores?|ram|memory|gb|tb|disk)\b/)
    signals << 'product version confirmed' if @corpus.match?(/chef.{0,30}\d+\.\d+|automate.{0,30}\d+\.\d+|infra.{0,30}\d+\.\d+|workstation.{0,30}\d+\.\d+/)

    verdict(
      item:     'Customer environment & product version',
      signals:  signals,
      threshold: 2,
      gap:      'OS, exact product version, and hardware specs must all be confirmed'
    )
  end

  # 2 — Full logs (all nodes, not partial)
  def check_logs
    signals = []
    signals << 'support bundle gathered'    if @corpus.match?(/support.?bundle|gatherlogs|gather.?log/)
    signals << 'logs shared/attached'       if @corpus.match?(/attached|log.{0,20}(share|upload|send|provid)|output below/)
    signals << 'multiple nodes referenced'  if @corpus.match?(/\b(all nodes|each node|cluster|multi.?node|ha setup|node\s+\d)\b/)
    signals << 'log excerpts present'       if @corpus.match?(/exception|stack.?trace|error.{0,40}log/)

    verdict(
      item:      'Full logs (all nodes, not partial)',
      signals:   signals,
      threshold: 2,
      gap:       'Full log bundle required across all nodes — not just a snippet or a single-node extract'
    )
  end

  # 3 — Initial RCA (root cause or hypothesis with evidence)
  def check_rca
    signals = []
    signals << 'root cause statement'  if @corpus.match?(/root.?cause|rca|cause.{0,30}(is|appears|seems|identified)/)
    signals << 'hypothesis stated'     if @corpus.match?(/\b(we believe|hypothesis|appears to be|likely caused|suspect|investigation (shows|suggests|indicates))\b/)
    signals << 'evidence-linked cause' if @corpus.match?(/the (error|issue|problem|failure) (is|occurs|happens|was caused|stems)/)

    verdict(
      item:      'Initial RCA (root cause or hypothesis with evidence)',
      signals:   signals,
      threshold: 1,
      gap:       'A root cause statement or leading hypothesis with supporting log evidence is required'
    )
  end

  # 4 — Workarounds attempted (incl. CA/DD guidance)
  def check_workarounds
    signals = []
    signals << 'workaround documented'    if @corpus.match?(/workaround|work.?around/)
    signals << 'troubleshooting attempted' if @corpus.match?(/\b(tried|attempted|tested|confirmed|replicated)\b/)
    signals << 'CA/DD consulted'          if @corpus.match?(/tom gordon|dd team|customer architect|professional services|\bca\b.{0,10}team/)
    signals << 'no workaround (stated)'   if @corpus.match?(/no (known )?workaround|unable to work.?around|cannot work.?around/)

    verdict(
      item:      'Workarounds attempted (incl. CA/DD guidance)',
      signals:   signals,
      threshold: 1,
      gap:       'Document workarounds tried and outcomes; note whether CA/DD were consulted or were unavailable'
    )
  end

  # 5 — Steps to reproduce (or formal note if not feasible)
  def check_reproduce
    signals = []
    signals << 'reproduction steps described' if @corpus.match?(/repro(duc|lic)|steps to repro|how to repro/)
    signals << 'lab/test environment used'    if @corpus.match?(/\b(lab|test.{0,10}(env|environment|system)|vagrant|vm|reproduced in)\b/)
    signals << 'consistent reproduction'      if @corpus.match?(/consistently|reliably|every time|always (happens|fails|occurs)/)
    signals << 'not feasible (stated)'        if @corpus.match?(/cannot (be )?reproduced|not (easily )?reproduced|reproduction.{0,20}(not possible|impossible|difficult|requires full)/)

    verdict(
      item:      'Steps to reproduce (or formal note if not feasible)',
      signals:   signals,
      threshold: 1,
      gap:       'Provide full reproduction steps OR a formal note explaining why reproduction is not feasible, with evidence-based RCA as substitute'
    )
  end

  # 6 — AI-assisted analysis used
  def check_ai_used
    signals = []
    signals << 'checkit run'           if @corpus.match?(/checkit|bundle.{0,30}analys/)
    signals << 'Copilot/AI analysis'   if @corpus.match?(/copilot|ai.{0,20}(analys|review|assist)|github copilot/)
    signals << 'RAG KB searched'       if @corpus.match?(/rag|knowledge.?base|\bkb\b.{0,20}search|prior.{0,20}cases?/)

    verdict(
      item:      'AI-assisted analysis (checkit, Copilot, RAG KB)',
      signals:   signals,
      threshold: 1,
      gap:       'Confirm AI tooling was used; note any gaps where AI did not surface the issue'
    )
  end

  # ── Additional checks ────────────────────────────────────────────────────────

  def check_jira_linked
    refs = @corpus.scan(/chef-\d+/).map(&:upcase).uniq
    {
      item:     'Existing Jira ticket check',
      status:   refs.any? ? 'green' : 'amber',
      evidence: refs.any? ? "Found in comments: #{refs.join(', ')}" : 'No CHEF-XXXXX reference found in case',
      gap:      refs.empty? ? 'Search CHEF project before raising a new ticket — avoid duplicates' : nil
    }
  end

  def check_severity
    sev     = @case['Severity__c'].to_s
    subject = @case['Subject'].to_s.downcase
    flag    = subject.match?(/\b(down|outage|unavailable|production|emergency)\b/)

    {
      item:     'Severity correct',
      status:   'green',
      evidence: "Current severity: #{sev}#{flag ? ' — subject line suggests possible severity mismatch' : ''}",
      gap:      flag ? 'Review whether current severity accurately reflects customer impact' : nil
    }
  end

  def check_account_risk
    account  = @case.dig('Account', 'Name').to_s
    is_red   = RED_ACCOUNTS.any?    { |a| account.downcase.include?(a.downcase) }
    is_yellow = YELLOW_ACCOUNTS.any? { |a| account.downcase.include?(a.downcase) }

    {
      item:     'Account risk level',
      status:   is_red ? 'red' : is_yellow ? 'amber' : 'green',
      evidence: is_red   ? '🔴 RED account — churn risk, elevated handling required' :
                is_yellow ? '🟡 YELLOW account — at risk, handle with care' :
                            'No account risk flag',
      gap:      (is_red || is_yellow) ? 'Loop in your team lead before or immediately after escalating' : nil
    }
  end

  def check_customer_updated
    public_comments = @comments.select { |c| c['IsPublished'] }
    return { item: 'Customer kept updated', status: 'amber', evidence: 'No public comments found', gap: 'Send a holding update before escalating' } if public_comments.empty?

    last = public_comments.last
    date = Time.parse(last['CreatedDate']) rescue nil
    days = date ? ((Time.now - date) / 86400).round : nil

    {
      item:     'Customer kept updated during investigation',
      status:   days && days > 7 ? 'amber' : 'green',
      evidence: "Last public comment: #{date&.strftime('%d/%m/%Y')} (#{days} days ago) by #{last.dig('CreatedBy', 'Name')}",
      gap:      days && days > 7 ? 'Last customer-facing update was over a week ago — send a holding update before escalating' : nil
    }
  end

  # ── Product / version detection & form pre-population ───────────────────────

  def detect_product
    search_text = "#{@case['Subject']} #{@case['Description']}"
    PRODUCT_KEYWORDS.each { |product, pattern| return product if search_text.match?(pattern) }
    PRODUCT_KEYWORDS.each { |product, pattern| return product if @corpus.match?(pattern) }
    nil
  end

  def detect_version
    ["#{@case['Subject']} #{@case['Description']}", @corpus[0, 3000]].each do |text|
      m = text.match(/\bv?(\d+\.\d+\.\d+(?:\.\d+)?)\b/)
      return m[1] if m
    end
    nil
  end

  def extract_environment_hint
    hints = []
    os_match = @corpus.match(/\b(ubuntu[\s\d.]*|rhel[\s\d.]*|centos[\s\d.]*|debian[\s\d.]*|windows server[\s\d.]*|amazon linux[\s\d.]*|suse[\s\d.]*|rocky linux[\s\d.]*|alma linux[\s\d.]*)/)
    hints << "OS: #{os_match[0].strip}" if os_match
    product = detect_product
    if product
      ver_pattern = /#{Regexp.escape(product.downcase)}.{0,30}v?(\d+\.\d+\.\d+)/i
      m = @corpus.match(ver_pattern)
      hints << "#{product}: #{m[1]}" if m
    end
    hints.empty? ? nil : hints.join(' | ')
  end

  def generate_headline
    product = detect_product
    version = detect_version
    subject = @case['Subject'].to_s.strip
    prefix  = [product, version && "v#{version}"].compact.join(' ')
    prefix.empty? ? subject : "[#{prefix}] #{subject}"
  end

  def pre_populate_form
    {
      headline:         generate_headline,
      product:          detect_product,
      found_in_release: detect_version,
      environment_hint: extract_environment_hint
    }
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def verdict(item:, signals:, threshold:, gap:)
    status = if signals.length >= threshold then 'green'
             elsif signals.length > 0       then 'amber'
             else                                'red'
             end

    {
      item:     item,
      status:   status,
      evidence: signals.empty? ? nil : signals.join('; '),
      gap:      status == 'green' ? nil : gap
    }
  end
end
