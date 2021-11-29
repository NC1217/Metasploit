##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Auxiliary

  # Exploit mixins should be called first
  include Msf::Exploit::Remote::SMB::Client
  include Msf::Exploit::Remote::SMB::Client::Authenticated
  include Msf::Exploit::Remote::DCERPC

  # Scanner mixin should be near last
  include Msf::Auxiliary::Report
  include Msf::Auxiliary::Scanner

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'SMB Share Enumeration',
        'Description' => %q{
          This module determines what shares are provided by the SMB service and which ones
          are readable/writable. It also collects additional information such as share types,
          directories, files, time stamps, etc.

          By default, a RubySMB net_share_enum_all request is done in order to retrieve share information,
          which uses SRVSVC.
        },
        'Author' => [
          'hdm',
          'nebulus',
          'sinn3r',
          'r3dy',
          'altonjx',
          'sjanusz-r7'
        ],
        'License' => MSF_LICENSE,
        'DefaultOptions' => {
          'DCERPC::fake_bind_multi' => false
        }
      )
    )

    register_options(
      [
        OptBool.new('SpiderShares', [false, 'Spider shares recursively', false]),
        OptBool.new('ShowFiles', [true, 'Show detailed information when spidering', false]),
        OptBool.new('SpiderProfiles', [false, 'Spider only user profiles when share is a disk share', true]),
        OptEnum.new('LogSpider', [false, '0 = disabled, 1 = CSV, 2 = table (txt), 3 = one liner (txt)', 3, [0, 1, 2, 3]]),
        OptInt.new('MaxDepth', [true, 'Max number of subdirectories to spider', 999]),
      ]
    )

    deregister_options('RPORT')
  end

  # Updated types for RubySMB. These are all the types we can ever receive from calling net_share_enum_all
  ENUMERABLE_SHARE_TYPES = ['DISK', 'TEMPORARY'].freeze
  SKIPPABLE_SHARE_TYPES = ['PRINTER', 'IPC', 'DEVICE', 'SPECIAL'].freeze
  SKIPPABLE_SHARES = ['ADMIN$', 'IPC$'].freeze

  # By default all of the drives connected to the server can be seen
  DEFAULT_SHARES = [
    'C$', 'D$', 'E$', 'F$', 'G$', 'H$', 'I$', 'J$', 'K$', 'L$', 'M$', 'N$',
    'O$', 'P$', 'Q$', 'R$', 'S$', 'T$', 'U$', 'V$', 'W$', 'X$', 'Y$', 'Z$'
  ].freeze

  USERS_SHARE = 'Users'.freeze # Where the users are stored in Windows 7
  USERS_DIR = '\Users'.freeze # Windows 7 & Windows 10 user directory
  DOCUMENTS_DIR = '\Documents and Settings'.freeze # Windows XP user directory

  SMB1_PORT = 139
  SMB2_3_PORT = 445

  def rport
    @rport || datastore['RPORT']
  end

  def enum_tree(tree, share, subdir = '')
    subdir = subdir[1..subdir.length] if subdir.starts_with?('\\')
    read = tree.permissions.read_ea == 1
    write = tree.permissions.write_ea == 1
    skip = false

    if ENUMERABLE_SHARE_TYPES.include?(share[:type])
      msg = share[:type]
    elsif SKIPPABLE_SHARE_TYPES.include?(share[:type])
      msg = share[:type]
      skip = true
    else
      msg = "Unhandled Device Type (#{share[:type]})"
      skip = true
    end

    print_status("Skipping share #{share[:name].strip} as it is of type #{share[:type]}") if skip
    return read, write, msg, nil if skip

    # Create list after possibly skipping a share we wouldn't be able to access.
    begin
      list = tree.list(directory: subdir)
    rescue RubySMB::Error::UnexpectedStatusCode => e
      vprint_error("Error when trying to list tree contents in #{share[:name]}\\#{subdir} - #{e.status_code.name}")
      return read, write, msg, nil
    end

    rfd = []
    unless list.nil? || list.empty?
      list.entries.each do |file|
        file_name = file.file_name.strip.encode('UTF-8')
        next if file_name == '.' || file_name == '..'

        rfd.push(file)
      end
    end

    return read, write, msg, rfd
  end

  def get_os_info(ip)
    os = smb_fingerprint
    if os['os'] != 'Unknown'
      os_info = "#{os['os']} #{os['sp']} (#{os['lang']})"
    end
    if os_info
      report_service(
        host: ip,
        port: rport,
        proto: 'tcp',
        name: 'smb',
        info: os_info
      )
    end

    os_info
  end

  def get_user_dirs(tree, share, base)
    dirs = []

    read, _write, _type, files = enum_tree(tree, share, base)

    return dirs if files.nil? || !read

    files.each do |f|
      dirs.push("\\#{base}\\#{f[:file_name].encode('UTF-8')}")
    end

    dirs
  end

  def profile_options(tree, share)
    dirs = get_user_dirs(tree, share, 'Documents and Settings')
    if dirs.blank?
      dirs = get_user_dirs(tree, share, 'Users')
    end

    dirs
  end

  def get_files_info(ip, shares)
    # Creating a separate file for each IP address's results.
    detailed_tbl = Rex::Text::Table.new(
      'Header' => "Spidered results for #{ip}.",
      'Indent' => 1,
      'Columns' => [ 'IP Address', 'Type', 'Share', 'Path', 'Name', 'Created', 'Accessed', 'Written', 'Changed', 'Size' ]
    )

    logdata = ''

    shares.each do |share|
      share_name = share[:name].strip
      if SKIPPABLE_SHARES.include?(share_name) || (share_name == USERS_SHARE && !datastore['SpiderProfiles'])
        print_status("Skipping #{share_name}")
        next
      end

      if !datastore['ShowFiles']
        print_status("Spidering #{share_name}")
      end

      begin
        tree = simple.client.tree_connect("\\\\#{ip}\\#{share_name}")
      rescue RubySMB::Error::UnexpectedStatusCode, RubySMB::Error::InvalidPacket => e
        vprint_error("Error when trying to connect to share #{share_name} - #{e.status_code.name}")
        print_status("Spidering #{share_name} complete") unless datastore['ShowFiles']
        next
      end

      subdirs = ['']
      if DEFAULT_SHARES.include?(share_name) && datastore['SpiderProfiles']
        subdirs = profile_options(tree, share)
      end
      until subdirs.empty?
        # Skip user directories if we do not want to spider them
        if (subdirs.first == USERS_DIR || subdirs.first == DOCUMENTS_DIR) && !datastore['SpiderProfiles']
          subdirs.shift
          next
        end
        depth = subdirs.first.count('\\')

        if DEFAULT_SHARES.include?(share_name) && datastore['SpiderProfiles'] && ((depth - 2) > datastore['MaxDepth'])
          subdirs.shift
          next
        end

        read, _write, _type, files = enum_tree(tree, share, subdirs.first)

        if files.nil? || files.empty? || !read
          subdirs.shift
          next
        end

        header = ''
        if simple.client.default_domain && simple.client.default_name
          header << " \\\\#{simple.client.default_domain}"
        end
        header << "\\#{share_name}" if simple.client.default_name
        header << subdirs.first
        pretty_tbl = Rex::Text::Table.new(
          'Header' => header,
          'Indent' => 1,
          'Columns' => [ 'Type', 'Name', 'Created', 'Accessed', 'Written', 'Changed', 'Size' ]
        )

        files.each do |file|
          fname = file.file_name.encode('UTF-8')
          tcr = file.create_time.to_datetime
          tac = file.last_access.to_datetime
          twr = file.last_write.to_datetime
          tch = file.last_change.to_datetime

          # Add subdirectories to list to use if SpiderShare is enabled.
          if (file[:file_attributes]&.directory == 1) || (file[:ext_file_attributes]&.directory == 1)
            fa = 'DIR'
            subdirs.push(subdirs.first + '\\' + fname)
          else
            fa = 'FILE'
            sz = file.end_of_file
          end

          # Filename is too long for the UI table, cut it.
          fname = "#{fname[0, 35]}..." if fname.length > 35

          pretty_tbl << [fa || 'Unknown', fname, tcr, tac, twr, tch, sz]
          detailed_tbl << [ip.to_s, fa || 'Unknown', share_name, subdirs.first + '\\', fname, tcr, tac, twr, tch, sz]
          logdata << "#{ip}\\#{share_name}#{subdirs.first}\\#{fname.encode}\n"
        end
        print_good(pretty_tbl.to_s) if datastore['ShowFiles']
        subdirs.shift
      end
      print_status("Spidering #{share_name} complete") unless datastore['ShowFiles']
    end

    unless detailed_tbl.rows.empty?
      if datastore['LogSpider'] == '1'
        p = store_loot('smb.enumshares', 'text/csv', ip, detailed_tbl.to_csv)
        print_good("info saved in: #{p}")
      elsif datastore['LogSpider'] == '2'
        p = store_loot('smb.enumshares', 'text/plain', ip, detailed_tbl)
        print_good("info saved in: #{p}")
      elsif datastore['LogSpider'] == '3'
        p = store_loot('smb.enumshares', 'text/plain', ip, logdata)
        print_good("info saved in: #{p}")
      end
    end
  end

  def run_host(ip)
    shares = []

    [{ port: SMB1_PORT }, { port: SMB2_3_PORT } ].each do |info|
      # Assign @rport so that it is accessible via the rport method in this module,
      # as well as making it accessible to the module mixins
      @rport = info[:port]

      begin
        print_status 'Starting module'
        if rport == SMB1_PORT
          connect(versions: [1])
        else
          connect(versions: [1, 2, 3])
        end
        smb_login

        begin
          shares = simple.client.net_share_enum_all(ip)
        rescue RubySMB::Error::UnexpectedStatusCode => e
          print_error("Error when trying to enumerate shares - #{e.status_code.name}")
          next
        rescue RubySMB::Error::InvalidPacket => e
          print_error("Invalid packet received when trying to enumerate shares - #{e}")
          next
        end

        os_info = get_os_info(ip)
        print_status(os_info) if os_info

        if shares.empty?
          print_status('No shares available')
        else
          shares.each do |share|
            print_good("#{share[:name]} - (#{share[:type]}) #{share[:comment]}")
          end

          # Map RubySMB shares to the same data format as it was with Rex SMB
          report_shares = shares.map { |share| [share[:name], share[:type], share[:comment]] }
          report_note(
            host: ip,
            proto: 'tcp',
            port: rport,
            type: 'smb.shares',
            data: { shares: report_shares },
            update: :unique_data
          )

          if datastore['SpiderShares']
            get_files_info(ip, shares)
          end
        end
      rescue ::Interrupt
        raise $ERROR_INFO
      rescue Errno::ECONNRESET => e
        vprint_error(e.message)
      rescue Errno::ENOPROTOOPT
        print_status('Wait 5 seconds before retrying...')
        select(nil, nil, nil, 5)
        retry
      rescue Rex::ConnectionTimeout => e
        print_error(e.to_s)
        return
      rescue Rex::Proto::SMB::Exceptions::LoginError => e
        print_error(e.to_s)
      rescue RubySMB::Error::RubySMBError => e
        print_error("RubySMB encountered an error: #{e}")
        return
      rescue RuntimeError => e
        print_error e.to_s
        return
      rescue StandardError => e
        vprint_error("Error: '#{ip}' '#{e.class}' '#{e}'")
      ensure
        disconnect
      end

      # if we already got results, not need to try on another port
      return unless shares.empty?
    end
  end
end
