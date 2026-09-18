# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

desc "Syntax-check the JavaScript that runs in the bridge and the page"
task :jscheck do
  Dir["lib/wrangle/js/*.js"].each do |file|
    abort "node --check failed: #{file}" unless system("node", "--check", file, out: File::NULL)
    puts "ok #{file}"
  end
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
  task default: %i[test jscheck rubocop]
rescue LoadError
  task default: %i[test jscheck]
end
