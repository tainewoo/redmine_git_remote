require 'redmine/scm/adapters/git_adapter'
require 'pathname'
require 'fileutils'

class Repository::GitRemote < Repository::Git

  PLUGIN_ROOT = Pathname.new(__FILE__).join("../../../..").realpath.to_s
  PATH_PREFIX = PLUGIN_ROOT + "/repos/"

  before_validation :initialize_clone

  # TODO: figureo ut how to do this safely (if at all)
  # before_deletion :rm_removed_repo
  # def rm_removed_repo
  #   if Repository.find_all_by_url(repo.url).length <= 1
  #     system "rm -Rf #{self.clone_url}"
  #   end
  # end

  def extra_clone_url
    return nil unless extra_info
    extra_info["extra_clone_url"]
  end

  def clone_url
    self.extra_clone_url
  end

  def clone_path
    self.url
  end

  def clone_host
    p = parse(clone_url)
    return p[:host]
  end

  # hook into Repository.fetch_changesets to also run 'git fetch'
  def fetch_changesets
    puts "Calling fetch changesets on #{clone_path}"
    # runs git fetch
    self.fetch
    super
  end

  # called in before_validate handler, sets form errors
  def initialize_clone
    # avoids crash in RepositoriesController#destroy
    return unless attributes["extra_info"]["extra_clone_url"]
    
    p = parse(attributes["extra_info"]["extra_clone_url"])
    self.identifier = p[:identifier] if identifier.empty?
    self.url = PATH_PREFIX + p[:path] if url.empty?

    err = clone_empty
    errors.add :extra_clone_url, err if err 
  end

  # equality check ignoring trailing whitespace and slashes
  def two_remotes_equal(a,b)
    a.chomp.gsub(/\/$/,'') == b.chomp.gsub(/\/$/,'')
  end

  def clone_empty
    Repository::GitRemote.add_known_host(clone_host)

    unless system "git ls-remote -h #{clone_url}"
      return "#{clone_url} is not a valid remote."
    end

    if Dir.exists? clone_path
      existing_repo_remote = `git -C #{clone_path} config --get remote.origin.url`
      unless two_remotes_equal(existing_repo_remote, clone_url)
        return "Clone path '#{clone_path}' already exits, unmatching clone url: #{existing_repo_remote}"
      end
    else
      unless system "git init --bare #{clone_path}"
        return  "Unable to run git init at #{clone_path}"
      end

      unless system "git -C #{clone_path} remote add --tags --mirror=fetch origin #{clone_url}"
        return  "Unable to run: git -C #{clone_path} remote add #{clone_url}"
      end
    end
  end

  unloadable
  def self.scm_name
    'GitRemote'
  end

  def parse(url)
    ret = {}
    # start with http://github.com/evolvingweb/git_remote or git@git.ewdev.ca:some/repo.git
    ret[:url] = url
    # path is github.com/evolvingweb/muhc-ci
    ret[:path] = url
                    .gsub(/^.*:\/\//, '')    # Remove anything before ://
                    .gsub(/:/, '/')          # convert ":" to "/"
                    .gsub(/^.*@/, '')        # Remove anything before @
                    .gsub(/\.git$/, '')      # Remove trailing .git
    ret[:host] = ret[:path].split('/').first
    #TODO: handle project uniqueness automatically or prompt
    ret[:identifier] =   ret[:path].split('/').last.downcase
    return ret
  end

  def fetch
    puts "Fetching repo #{clone_path}"
    Repository::GitRemote.add_known_host(clone_host)

    err = clone_empty
    Rails.logger.warn err if err

    # If dir exists and non-empty, should be safe to 'git fetch'
    unless system "git -C #{clone_path} fetch --all"
      Rails.logger.warn "Unable to run 'git -c #{clone_path} fetch --all'"
    end
  end

  # Checks if host is in ~/.ssh/known_hosts, adds it if not present
  def self.add_known_host(host)
    # if not found...
    if `ssh-keygen -F #{host} | grep 'found'` == ""
      # hack to work with 'docker exec' where HOME isn't set (or set to /)
      ssh_dir = (ENV['HOME'] == "/" || ENV['HOME'] == nil ? "/root" : ENV['HOME']) + "/.ssh"
      ssh_known_hosts = ssh_dir + "/known_hosts"
      FileUtils.mkdir_p ssh_dir
      puts "Adding #{host} to #{ssh_known_hosts}"
      unless system `ssh-keyscan #{host} >> #{ssh_known_hosts}`
        Rails.logger.warn "Unable to add known host #{host} to #{ssh_known_hosts}"
      end
    end
  end

end