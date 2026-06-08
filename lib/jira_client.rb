require 'base64'
require 'json'
require 'net/http'
require 'uri'

# Queries the CHEF Jira project for potential duplicate tickets.
# Uses credentials from JIRA_EMAIL and JIRA_API_TOKEN env vars (same as
# the main Copilot CLI setup). Returns { available: false } if credentials
# are not present, so the caller can remind the engineer to search manually.
class JiraClient
  JIRA_URL = ENV['JIRA_URL'].to_s.strip.empty? ? nil : ENV['JIRA_URL'].freeze

  def self.available?
    ENV['JIRA_EMAIL'].to_s.strip.length > 0 &&
      ENV['JIRA_API_TOKEN'].to_s.strip.length > 0 &&
      !JIRA_URL.nil?
  end

  def self.search_duplicates(subject, product = nil)
    new.search_duplicates(subject, product)
  end

  # Returns:
  #   { available: false }                      — credentials absent
  #   { available: true, issues: [...], jql: }  — query ran
  #   { available: true, error: message }       — query failed
  def search_duplicates(subject, product = nil)
    return { available: false } unless JiraClient.available?

    stop_words = %w[the a an and or in on at to of for with is are was were this that]
    terms = subject.to_s.downcase
                   .split(/\W+/)
                   .reject { |w| stop_words.include?(w) || w.length < 4 }
                   .first(4)

    return { available: true, issues: [], jql: nil } if terms.empty?

    text_clauses = terms.map { |t| "\"#{t}\"" }.join(' ')
    jql = "project = CHEF AND text ~ (#{text_clauses}) ORDER BY created DESC"

    uri = URI("#{JIRA_URL}/rest/api/3/search/jql")
    uri.query = URI.encode_www_form(
      jql:        jql,
      maxResults: 5,
      fields:     'summary,status,assignee,fixVersions'
    )

    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Basic #{Base64.strict_encode64("#{ENV['JIRA_EMAIL']}:#{ENV['JIRA_API_TOKEN']}")}"
    req['Content-Type']  = 'application/json'

    http              = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.open_timeout = 10
    http.read_timeout = 15

    res = http.request(req)
    return { available: true, error: "Jira API returned #{res.code}" } unless res.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(res.body)

    issues = (parsed['issues'] || []).map do |i|
      {
        key:         i['key'],
        summary:     i.dig('fields', 'summary'),
        status:      i.dig('fields', 'status', 'name'),
        assignee:    i.dig('fields', 'assignee', 'displayName') || 'Unassigned',
        fix_version: Array(i.dig('fields', 'fixVersions')).map { |v| v['name'] }.first
      }
    end

    { available: true, issues: issues, jql: jql }
  rescue StandardError => e
    { available: true, error: e.message }
  end
end
