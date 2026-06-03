require 'json'
require 'net/http'
require 'open3'
require 'uri'
require 'fileutils'
require 'tmpdir'

# Wraps Salesforce REST API calls, authenticating via the `sf` CLI.
class SalesforceClient
  API_VERSION = 'v66.0'

  MAX_BUNDLE_BYTES   = 500 * 1024 * 1024  # 500 MB ceiling for downloads
  BUNDLE_NAME_RE     = /gatherlogs|support.?bundle|support_bundle/i
  BUNDLE_EXT_RE      = /\A(tar\.gz|tar\.bz2|tgz|tar|gz|bz2|zip)\z/i

  # Raised when the `sf` CLI is not installed or not on PATH.
  class SfCliNotFound < StandardError; end

  # Raised when the case number matches no record in Salesforce.
  class CaseNotFound < StandardError; end

  def self.fetch_case(case_number)
    new.fetch_case(case_number)
  end

  # Downloads the best support bundle attachment for a case to a local temp path.
  # Returns a structured result hash — never raises (failures are captured in :error).
  #
  # Result keys:
  #   :path             — local path to downloaded file (present on success)
  #   :filename         — sanitised filename
  #   :size             — bytes
  #   :matched_by       — :name | :extension (how the candidate was selected)
  #   :attachment_count — total attachments on the case
  #   :no_bundle        — true if attachments exist but none matched bundle patterns
  #   :error            — error message if download failed
  def self.fetch_bundle(case_id:, case_number:)
    new.fetch_bundle_for(case_id, case_number)
  end

  # Returns { case:, comments:, case_id:, case_number:, account: } or raises.
  def fetch_case(case_number)
    token, instance_url = auth

    case_soql = <<~SOQL.tr("\n", ' ').strip
      SELECT Id, CaseNumber, Subject, Status, Severity__c, Chef_Support_Level__c,
             AccountId, Account.Name, Contact.Name,
             CreatedDate, LastModifiedDate, LastModifiedBy.Name
      FROM Case
      WHERE CaseNumber = '#{case_number}'
    SOQL

    case_result = query(token, instance_url, case_soql)
    if case_result.is_a?(Array)
      raise "Salesforce query error: #{case_result.map { |e| e['message'] }.join('; ')}"
    end
    raise CaseNotFound, "Case #{case_number} not found in Salesforce" if case_result['records'].empty?

    kase    = case_result['records'][0]
    case_id = kase['Id']

    comment_soql = <<~SOQL.tr("\n", ' ').strip
      SELECT Id, CommentBody, CreatedDate, CreatedBy.Name, IsPublished
      FROM CaseComment
      WHERE ParentId = '#{case_id}'
      ORDER BY CreatedDate ASC
    SOQL

    comments   = fetch_all(token, instance_url, comment_soql)
    account_id = kase['AccountId']
    account    = account_id ? fetch_account(account_id, token, instance_url) : nil

    { case: kase, comments: comments, case_id: case_id, case_number: case_number, account: account }
  end

  # Bundle download — public surface is SalesforceClient.fetch_bundle
  def fetch_bundle_for(case_id, case_number)
    token, instance_url = auth
    attachments = fetch_attachments(case_id, token, instance_url)

    return { attachment_count: 0, no_bundle: true } if attachments.empty?

    candidate, matched_by = select_bundle_candidate(attachments)
    unless candidate
      return {
        attachment_count: attachments.length,
        no_bundle:        true,
        skipped:          summarise_attachments(attachments)
      }
    end

    download_bundle_file(candidate, matched_by, case_number, token, instance_url, attachments.length)
  rescue StandardError => e
    { error: e.message, attachment_count: 0 }
  end

  private

  # Returns all ContentDocumentLink records (file attachments) for a case.
  def fetch_attachments(case_id, token, instance_url)
    soql = <<~SOQL.tr("\n", ' ').strip
      SELECT ContentDocumentId,
             ContentDocument.Title,
             ContentDocument.FileExtension,
             ContentDocument.ContentSize,
             ContentDocument.LatestPublishedVersionId,
             ContentDocument.CreatedDate
      FROM ContentDocumentLink
      WHERE LinkedEntityId = '#{case_id}'
      ORDER BY ContentDocument.ContentSize DESC
    SOQL
    result = query(token, instance_url, soql)
    result.is_a?(Array) ? [] : (result['records'] || [])
  end

  # Selects the best bundle candidate. Returns [record, matched_by_symbol] or nil.
  # Priority: name match first, then extension match. Never falls back to "largest".
  def select_bundle_candidate(attachments)
    attachments.each do |a|
      title = a.dig('ContentDocument', 'Title').to_s
      return [a, :name] if title.match?(BUNDLE_NAME_RE)
    end

    attachments.each do |a|
      ext = a.dig('ContentDocument', 'FileExtension').to_s.downcase
      return [a, :extension] if BUNDLE_EXT_RE.match?(ext)
    end

    nil
  end

  # Downloads the candidate file to a per-case temp directory.
  def download_bundle_file(attachment, matched_by, case_number, token, instance_url, total_attachments)
    doc        = attachment['ContentDocument']
    title      = doc['Title'].to_s.strip
    ext        = doc['FileExtension'].to_s.strip.downcase
    version_id = doc['LatestPublishedVersionId']
    size       = doc['ContentSize'].to_i

    if size > MAX_BUNDLE_BYTES
      return {
        error:            "Attachment too large to download (#{(size / (1024.0 ** 2)).round(0).to_i} MB > 500 MB limit)",
        attachment_count: total_attachments
      }
    end

    filename = build_filename(title, ext, version_id)
    dir      = File.join(Dir.tmpdir, 'escalation-mcp', case_number.to_s)
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, filename)

    uri = URI("#{instance_url}/services/data/#{API_VERSION}/sobjects/ContentVersion/#{version_id}/VersionData")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.open_timeout = 15
    http.read_timeout = 300  # large bundles can be slow

    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{token}"

    begin
      http.request(req) do |resp|
        unless resp.code.to_i == 200
          raise "HTTP #{resp.code} downloading attachment (version #{version_id})"
        end
        File.open(dest, 'wb') { |f| resp.read_body { |chunk| f.write(chunk) } }
      end
    rescue StandardError => e
      File.delete(dest) if File.exist?(dest)
      raise
    end

    {
      path:             dest,
      filename:         filename,
      size:             size,
      matched_by:       matched_by,
      attachment_count: total_attachments
    }
  end

  # Builds a safe, collision-resistant filename from SF metadata.
  def build_filename(title, ext, version_id)
    # Sanitise title: keep word chars, dots, hyphens; collapse repeated underscores
    safe = title.gsub(/[^\w.\-]/, '_').squeeze('_').sub(/^_+|_+$/, '')
    safe = "bundle_#{version_id[0, 8]}" if safe.empty?

    # Append extension if not already present
    safe = "#{safe}.#{ext}" unless ext.empty? || safe.downcase.end_with?(".#{ext}")

    # Prefix with short version_id for uniqueness (avoids overwriting existing downloads)
    "#{version_id[0, 8]}_#{safe}"
  end

  def summarise_attachments(attachments)
    attachments.map do |a|
      doc = a['ContentDocument']
      "#{doc['Title']} (.#{doc['FileExtension']}, #{(doc['ContentSize'].to_i / 1024.0).round(0).to_i} KB)"
    end
  end

  # Resolves the SF org alias. Priority: SF_ORG_ALIAS env var → detected default → 'progress'
  def sf_org
    return ENV['SF_ORG_ALIAS'] if ENV['SF_ORG_ALIAS'].to_s.strip.length > 0

    stdout, _, status = Open3.capture3('sf', 'config', 'get', 'target-org', '--json')
    if status.success?
      value = JSON.parse(stdout).dig('result', 0, 'value').to_s.strip
      return value unless value.empty?
    end

    raise "No Salesforce org configured. Set SF_ORG_ALIAS or run: sf config set target-org <alias>"
  rescue SfCliNotFound
    raise
  rescue StandardError => e
    raise "Could not determine Salesforce org: #{e.message}. Set SF_ORG_ALIAS or run: sf config set target-org <alias>"
  end

  def auth
    unless sf_cli_available?
      raise SfCliNotFound, <<~MSG.strip
        The Salesforce CLI (`sf`) was not found on PATH.

        Install it with:
          brew install sf

        Or download from:
          https://developer.salesforce.com/tools/salesforcecli

        Once installed, authenticate with:
          sf org login web --alias <your-org-alias>
          export SF_ORG_ALIAS=<your-org-alias>
      MSG
    end

    org = sf_org
    stdout, stderr, status = Open3.capture3('sf', 'org', 'display', '--target-org', org, '--json')

    unless status.success?
      raise "sf org display failed — is the '#{org}' org authenticated?\n" \
            "Run: sf org login web --alias #{org}\n" \
            "Or set: export SF_ORG_ALIAS=<your-alias>\n\nDetails: #{stderr.strip}"
    end

    result = JSON.parse(stdout)['result']
    [result['accessToken'], result['instanceUrl']]
  end

  def sf_cli_available?
    system('which sf > /dev/null 2>&1')
  end

  def query(token, instance_url, soql)
    uri       = URI("#{instance_url}/services/data/#{API_VERSION}/query")
    uri.query = URI.encode_www_form(q: soql)

    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['Content-Type']  = 'application/json'

    http          = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl  = true
    http.open_timeout = 15
    http.read_timeout = 30

    JSON.parse(http.request(req).body)
  end

  # Fetches ARR and renewal date from the Account record. Returns nil on any failure.
  # AnnualRevenue is a standard SF field. Renewal date field name varies by org —
  # set SF_RENEWAL_DATE_FIELD env var to override (default: Contract_Expiration_Date__c).
  def fetch_account(account_id, token, instance_url)
    renewal_field = ENV.fetch('SF_RENEWAL_DATE_FIELD', 'Contract_Expiration_Date__c')
    soql = <<~SOQL.tr("\n", ' ').strip
      SELECT Id, Name, AnnualRevenue, #{renewal_field}
      FROM Account
      WHERE Id = '#{account_id}'
    SOQL
    result = query(token, instance_url, soql)
    result['records'].first
  rescue StandardError
    # Account query is best-effort; fall back gracefully
    begin
      fallback = query(token, instance_url, "SELECT Id, Name, AnnualRevenue FROM Account WHERE Id = '#{account_id}'")
      fallback['records'].first
    rescue StandardError
      nil
    end
  end

  # Follows nextRecordsUrl pagination until all records are retrieved.
  def fetch_all(token, instance_url, soql)
    result  = query(token, instance_url, soql)
    records = result['records'] || []

    next_url = result['nextRecordsUrl']
    while next_url
      uri       = URI("#{instance_url}#{next_url}")
      req       = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{token}"

      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      page         = JSON.parse(http.request(req).body)

      records  += page['records'] || []
      next_url  = page['nextRecordsUrl']
    end

    records
  end
end
