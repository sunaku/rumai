# Copyright 2007 Suraj N. Kurapati
# See the file named LICENSE for details.

require 'rake/clean'
require 'rake/rdoctask'
require 'rake/gempackagetask'

# documentation
  desc "Build the documentation."
  task :doc

  # the user guide
  file 'doc/guide.html' => 'doc/guide.erb' do |t|
    sh "gerbil html #{t.prerequisites} > #{t.name}"
  end
  task :doc => 'doc/guide.html'
  CLOBBER.include 'doc/guide.html'

# API reference
  desc "Build API reference."
  task :ref => 'doc/api'

  Rake::RDocTask.new 'doc/api' do |t|
    t.rdoc_dir = t.name
    t.rdoc_files.exclude('_darcs', 'pkg').include('**/*.rb')
  end

# packaging
  require 'lib/rumai/nfo' # project info

  spec = Gem::Specification.new do |s|
    s.name              = Rumai::NFO[:name].downcase
    s.version           = Rumai::NFO[:version]
    s.summary           = 'Ruby interface to wmii.'
    s.description       = s.summary
    s.homepage          = Rumai::NFO[:website]
    s.files             = FileList['**/*'].exclude('_darcs')
    s.executables       = s.name
    s.rubyforge_project = s.name
    s.has_rdoc          = true
  end

  Rake::GemPackageTask.new(spec) do |pkg|
    pkg.need_tar = true
  end

# releasing
  desc 'Build release packages.'
  task :dist => [:clobber, :doc, :ref] do
    system 'rake package'
  end

# utility
  desc 'Upload to project website.'
  task :upload => [:doc, :ref] do
    sh "rsync -av doc/ ~/www/lib/#{spec.name}"
    sh "rsync -av doc/api/ ~/www/lib/#{spec.name}/api/ --delete"
  end
