require 'time'
require 'date'
require 'base64'

# Extracts structured data from a Salesforce case for the escalation workflow.
#
# Checklist items 1–6 are scored by the AI agent, not by this class.
# This class handles only objective, mechanical checks that do not require
# semantic understanding: Jira ticket references, severity, account risk,
# and customer update recency.
class ChecklistEvaluator

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
  end

  def evaluate
    {
      case_summary:      case_summary,
      mechanical_checks: run_mechanical_checks,
      comment_count:     @comments.length,
      last_comment:      @comments.last,
      comments:          @comments,
      description:       @case['Question_Problem_Description__c'].to_s,
      error_message:     @case['Error_Message__c'].to_s
    }
  end

  private

  def case_summary
    arr           = @account&.[]('AnnualRevenue')
    renewal_field = ENV.fetch('SF_RENEWAL_DATE_FIELD', 'Contract_End_Date__c')
    renewal       = @account&.[](renewal_field)
    {
      case_number:      @case_number,
      subject:          @case['Subject'],
      status:           @case['Status'],
      severity:         @case['Severity__c'],
      support_level:    @case['Chef_Support_Level__c'],
      account:          @case.dig('Account', 'Name'),
      account_arr:      arr,
      account_renewal:  renewal,
      contact:          @case.dig('Contact', 'Name'),
      created:          @case['CreatedDate'],
      last_modified:    @case['LastModifiedDate'],
      last_modified_by: @case.dig('LastModifiedBy', 'Name')
    }
  end

  # ── Mechanical checks (objective, no semantic analysis) ──────────────────────

  def run_mechanical_checks
    [
      check_jira_linked,
      check_severity,
      check_account_risk,
      check_customer_updated
    ]
  end

  def check_jira_linked
    all_text = ([@case['Question_Problem_Description__c'].to_s] +
                @comments.map { |c| c['CommentBody'].to_s }).join("\n").downcase
    refs = all_text.scan(/chef-\d+/i).map(&:upcase).uniq
    {
      item:     'Existing Jira ticket check',
      status:   refs.any? ? 'green' : 'amber',
      evidence: refs.any? ? "Found in case: #{refs.join(', ')}" : 'No CHEF-XXXXX reference found in case',
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
    account   = @case.dig('Account', 'Name').to_s
    is_red    = RED_ACCOUNTS.any?    { |a| account.downcase.include?(a.downcase) }
    is_yellow = YELLOW_ACCOUNTS.any? { |a| account.downcase.include?(a.downcase) }
    {
      item:     'Account risk level',
      status:   is_red ? 'red' : is_yellow ? 'amber' : 'green',
      evidence: is_red    ? '🔴 RED account — churn risk, elevated handling required' :
                is_yellow ? '🟡 YELLOW account — at risk, handle with care' :
                            'No account risk flag',
      gap:      (is_red || is_yellow) ? 'Loop in your team lead before or immediately after escalating' : nil
    }
  end

  def check_customer_updated
    public_comments = @comments.select { |c| c['IsPublished'] }
    return { item: 'Customer kept updated during investigation', status: 'amber', evidence: 'No public comments found', gap: 'Send a holding update before escalating' } if public_comments.empty?

    last = public_comments.last
    body = last['CommentBody'].to_s.downcase
    auto_reply = body.match?(/out of office|i'm currently out|on leave|on holiday|will be back|auto.?reply|do not reply to this/)

    date = Time.parse(last['CreatedDate']) rescue nil
    days = date ? ((Time.now - date) / 86400).round : nil

    status = if auto_reply             then 'amber'
             elsif days && days > 7   then 'amber'
             else                          'green'
             end

    note = if auto_reply
             'Last public comment is an auto-reply — customer may not have received the update'
           elsif days && days > 7
             'Last customer-facing update was over a week ago — send a holding update before escalating'
           end

    {
      item:     'Customer kept updated during investigation',
      status:   status,
      evidence: "Last public comment: #{date&.strftime('%d/%m/%Y')} (#{days} days ago) by #{last.dig('CreatedBy', 'Name')}#{auto_reply ? ' [AUTO-REPLY]' : ''}",
      gap:      note
    }
  end
end
