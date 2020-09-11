require "active_support/all"
require "fileutils"
require_relative "rest_api"

class ScrivitoExport
  def export(dir_name:)
    base_url = ENV.fetch("SCRIVITO_BASE_URL") { "https://api.scrivito.com" }
    tenant = ENV.fetch("SCRIVITO_TENANT")
    api_key = ENV.fetch("SCRIVITO_API_KEY")
    api = RestApi.new(base_url, tenant, api_key)

    raise "file '#{dir_name}' exists" if File.exist?(dir_name)
    FileUtils.mkdir_p(dir_name)

    obj_count = 0
    File.open(File.join(dir_name, "objs.json"), "w") do |file|
      rev_id, obj_ids = get_obj_ids(api)
      exported_obj_ids = []
      relevant_obj_classes = nil
      while obj_ids.present?
        extra_obj_ids = []
        obj_ids.each do |id|
          obj = nil
          begin
            obj = api.get("revisions/#{rev_id}/objs/#{id}")
          rescue RestApi::ScrivitoError => e
            puts "ERROR: #{e})"
            next
          end
          obj_attrs, ref_obj_ids = export_attrs(api, obj, dir_name)
          if relevant_obj_classes && !relevant_obj_classes.include?(obj_attrs['_obj_class'])
            puts "SKIPPING: #{obj_attrs['_path']} (#{obj_attrs['_obj_class']})"
            next
          end
          extra_obj_ids.concat(ref_obj_ids)
          puts "Exporting: #{obj_attrs['_path']} (#{obj_attrs['_obj_class']})"
          file.write(JSON.generate(obj_attrs))
          file.write("\n")
          obj_count += 1
        end
        exported_obj_ids.concat(obj_ids)
        obj_ids = extra_obj_ids - exported_obj_ids
        relevant_obj_classes = ["Image", "Download"]
        puts "HALLO: #{obj_ids.size}"
      end
    end
    puts "Exported #{obj_count} objects to #{dir_name}/objs.json"
  end

  private

  def export_attrs(api, attrs, dir_name)
    extra_obj_ids = []
    res = attrs.inject({}) do |h, (k, v)|
      h[k] =
        if k == "_widget_pool"
          v.inject({}) do |h1, (k1, v1)|
            h1[k1], extra_obj_ids2 = export_attrs(api, v1, dir_name)
            extra_obj_ids.concat(extra_obj_ids2)
            h1
          end
        elsif k.starts_with?("_")
          v
        else
          case v.first
          when "reference"
            extra_obj_ids << v.last if v.last.present?
            v
          when "referencelist"
            extra_obj_ids.concat(v.last) if v.last.present?
            v
          when "link"
            obj_id = export_link(v.last)
            extra_obj_ids << obj_id if obj_id.present?
            v
          when "linklist"
            obj_ids = v.last&.map{|link| export_link(link)}&.compact
            extra_obj_ids.concat(obj_ids) if obj_ids
            v
          when "binary"
            ["binary", {"file" => export_binary(api, v.last["id"], dir_name)}]
          else
            v
          end
        end
      h
    end
    [res, extra_obj_ids]
  end

  def export_link(link)
    return unless link
    link["obj_id"]
  end

  def export_binary(api, binary_id, dir_name)
    blob_id = api.normalize_path_component(binary_id)
    url = api.get("blobs/#{blob_id}")["private_access"]["get"]["url"]
    filename = "#{File.dirname(binary_id).parameterize}-#{File.basename(binary_id)}"
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(uri)
      http.request(request) do |response|
        open(File.join(dir_name, filename), "wb") do |io|
          response.read_body do |chunk|
            io.write chunk
          end
        end
      end
    end
    filename
  end

  def get_obj_ids(api)
    before_published_rev_id = api.get("workspaces/published")["revision_id"]
    continuation = nil
    ids = []
    begin
      w = api.get(
        "workspaces/published/objs/search",
        "continuation" => continuation,
        "query" => [{field: '_path', operator: 'prefix', value: ['/dawn_master/en/laboratory-diagnostics', '/dawn_master/en/medical-imaging']}],
      )
      ids += w["results"].map {|r| r["id"]}
    end while (continuation = w["continuation"]).present?
    after_published_rev_id = api.get("workspaces/published")["revision_id"]
    if after_published_rev_id != before_published_rev_id
      raise "published working copy has changed during obj search"
    end
    [after_published_rev_id, ids]
  end
end

dir_name = ARGV.first or raise "missing dir_name param"
ScrivitoExport.new.export(dir_name: dir_name)
