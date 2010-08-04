require "isolation/abstract_unit"
require "railties/shared_tests"
require 'stringio'

module RailtiesTest
  class EngineTest < Test::Unit::TestCase
    # TODO: it's copied from generators/test_case, maybe make a module with such helpers?
    def capture(stream)
      begin
        stream = stream.to_s
        eval "$#{stream} = StringIO.new"
        yield
        result = eval("$#{stream}").string
      ensure
        eval("$#{stream} = #{stream.upcase}")
      end

      result
    end

    include ActiveSupport::Testing::Isolation
    include SharedTests

    def setup
      build_app

      @plugin = engine "bukkits" do |plugin|
        plugin.write "lib/bukkits.rb", <<-RUBY
          class Bukkits
            class Engine < ::Rails::Engine
              railtie_name "bukkits"
            end
          end
        RUBY
        plugin.write "lib/another.rb", "class Another; end"
      end
    end

    test "Rails::Engine itself does not respond to config" do
      boot_rails
      assert !Rails::Engine.respond_to?(:config)
    end

    test "initializers are executed after application configuration initializers" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
            initializer "dummy_initializer" do
            end
          end
        end
      RUBY

      boot_rails

      initializers = Rails.application.initializers.tsort
      index        = initializers.index { |i| i.name == "dummy_initializer" }

      assert index > initializers.index { |i| i.name == :load_config_initializers }
      assert index > initializers.index { |i| i.name == :engines_blank_point }
      assert index < initializers.index { |i| i.name == :build_middleware_stack }
    end

    class Upcaser
      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)
        response[2].upcase!
        response
      end
    end

    test "engine is a rack app and can have his own middleware stack" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
            endpoint lambda { |env| [200, {'Content-Type' => 'text/html'}, 'Hello World'] }

            config.middleware.use ::RailtiesTest::EngineTest::Upcaser
          end
        end
      RUBY

      app_file "config/routes.rb", <<-RUBY
        AppTemplate::Application.routes.draw do
          mount(Bukkits::Engine => "/bukkits")
        end
      RUBY

      boot_rails

      env = Rack::MockRequest.env_for("/bukkits")
      response = Rails.application.call(env)

      assert_equal "HELLO WORLD", response[2]
    end

    test "it provides routes as default endpoint" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
          end
        end
      RUBY

      @plugin.write "config/routes.rb", <<-RUBY
        Bukkits::Engine.routes.draw do
          match "/foo" => lambda { |env| [200, {'Content-Type' => 'text/html'}, 'foo'] }
        end
      RUBY

      app_file "config/routes.rb", <<-RUBY
        Rails.application.routes.draw do
          mount(Bukkits::Engine => "/bukkits")
        end
      RUBY

      boot_rails

      env = Rack::MockRequest.env_for("/bukkits/foo")
      response = Rails.application.call(env)

      assert_equal "foo", response[2]
    end

    test "engine can load its own plugins" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
          end
        end
      RUBY

      @plugin.write "vendor/plugins/yaffle/init.rb", <<-RUBY
        config.yaffle_loaded = true
      RUBY

      boot_rails

      assert Bukkits::Engine.config.yaffle_loaded
    end

    test "engine does not load plugins that already exists in application" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
          end
        end
      RUBY

      @plugin.write "vendor/plugins/yaffle/init.rb", <<-RUBY
        config.engine_yaffle_loaded = true
      RUBY

      app_file "vendor/plugins/yaffle/init.rb", <<-RUBY
        config.app_yaffle_loaded = true
      RUBY

      warnings = capture(:stderr) { boot_rails }

      assert !warnings.empty?
      assert !Bukkits::Engine.config.respond_to?(:engine_yaffle_loaded)
      assert Rails.application.config.app_yaffle_loaded
    end

    test "it loads its environment file" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
          end
        end
      RUBY

      @plugin.write "config/environments/development.rb", <<-RUBY
        Bukkits::Engine.configure do
          config.environment_loaded = true
        end
      RUBY

      boot_rails

      assert Bukkits::Engine.config.environment_loaded
    end

    test "it passes router in env" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
            endpoint lambda { |env| [200, {'Content-Type' => 'text/html'}, 'hello'] }
          end
        end
      RUBY

      boot_rails

      env = Rack::MockRequest.env_for("/")
      response = Bukkits::Engine.call(env)

      assert_equal Bukkits::Engine.routes, env['action_dispatch.routes']

      env = Rack::MockRequest.env_for("/")
      response = Rails.application.call(env)

      assert_equal Rails.application.routes, env['action_dispatch.routes']
    end

    test "it allows to set asset_path" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
          end
        end
      RUBY


      @plugin.write "config/routes.rb", <<-RUBY
        Bukkits::Engine.routes.draw do
          match "/foo" => "foo#index"
        end
      RUBY

      @plugin.write "app/controllers/foo_controller.rb", <<-RUBY
        class FooController < ActionController::Base
          def index
            render :index
          end
        end
      RUBY

      @plugin.write "app/views/foo/index.html.erb", <<-RUBY
        <%= compute_public_path("/foo", "") %>
        <%= image_path("foo.png") %>
        <%= javascript_include_tag("foo") %>
        <%= stylesheet_link_tag("foo") %>
      RUBY


      app_file "app/controllers/bar_controller.rb", <<-RUBY
        class BarController < ActionController::Base
          def index
            render :index
          end
        end
      RUBY

      app_file "app/views/bar/index.html.erb", <<-RUBY
        <%= compute_public_path("/foo", "") %>
      RUBY

      add_to_config 'config.asset_path = "/omg%s"'

      @plugin.write 'public/touch.txt', <<-RUBY
        touch
      RUBY

      boot_rails

      # should set asset_path with engine name by default
      assert_equal "/bukkits_engine%s", ::Bukkits::Engine.config.asset_path

      ::Bukkits::Engine.config.asset_path = "/bukkits%s"

      env = Rack::MockRequest.env_for("/foo")
      response = Bukkits::Engine.call(env)
      stripped_body = response[2].body.split("\n").map(&:strip).join("\n")

      expected =  "/omg/bukkits/foo\n" +
                  "/omg/bukkits/images/foo.png\n" +
                  "<script src=\"/omg/bukkits/javascripts/foo.js\" type=\"text/javascript\"></script>\n" +
                  "<link href=\"/omg/bukkits/stylesheets/foo.css\" media=\"screen\" rel=\"stylesheet\" type=\"text/css\" />"
      assert_equal expected, stripped_body
    end

    test "engine's files are served via ActionDispatch::Static" do
      add_to_config "config.serve_static_assets = true"

      @plugin.write "lib/bukkits.rb", <<-RUBY
        class Bukkits
          class Engine < ::Rails::Engine
            engine_name :bukkits
          end
        end
      RUBY

      @plugin.write "public/bukkits.html", "/bukkits/bukkits.html"
      app_file "public/app.html", "/app.html"

      boot_rails

      env = Rack::MockRequest.env_for("/app.html")
      response = Rails.application.call(env)
      assert_equal response[2].path, File.join(app_path, "public/app.html")

      env = Rack::MockRequest.env_for("/bukkits/bukkits.html")
      response = Rails.application.call(env)
      assert_equal response[2].path, File.join(@plugin.path, "public/bukkits.html")
    end

    test "shared engine should include application's helpers" do
      app_file "config/routes.rb", <<-RUBY
        AppTemplate::Application.routes.draw do
          match "/foo" => "bukkits/foo#index", :as => "foo"
          match "/foo/show" => "bukkits/foo#show"
        end
      RUBY

      app_file "app/helpers/some_helper.rb", <<-RUBY
        module SomeHelper
          def something
            "Something... Something... Something..."
          end
        end
      RUBY

      @plugin.write "app/controllers/bukkits/foo_controller.rb", <<-RUBY
        class Bukkits::FooController < ActionController::Base
          def index
            render :inline => "<%= something %>"
          end

          def show
            render :text => foo_path
          end
        end
      RUBY

      boot_rails

      env = Rack::MockRequest.env_for("/foo")
      response = Rails.application.call(env)
      assert_equal "Something... Something... Something...", response[2].body

      env = Rack::MockRequest.env_for("/foo/show")
      response = Rails.application.call(env)
      assert_equal "/foo", response[2].body
    end

    test "namespaced engine should include only its own routes and helpers" do
      @plugin.write "lib/bukkits.rb", <<-RUBY
        module Bukkits
          class Engine < ::Rails::Engine
            namespace Bukkits
          end
        end
      RUBY

      app_file "config/routes.rb", <<-RUBY
        AppTemplate::Application.routes.draw do
          match "/bar" => "bar#index", :as => "bar"
          mount Bukkits::Engine => "/bukkits", :as => "bukkits"
        end
      RUBY

      @plugin.write "config/routes.rb", <<-RUBY
        Bukkits::Engine.routes.draw do
          match "/foo" => "bukkits/foo#index", :as => "foo"
          match "/foo/show" => "bukkits/foo#show"
          match "/from_app" => "bukkits/foo#from_app"
          match "/routes_helpers_in_view" => "bukkits/foo#routes_helpers_in_view"
        end
      RUBY

      app_file "app/helpers/some_helper.rb", <<-RUBY
        module SomeHelper
          def something
            "Something... Something... Something..."
          end
        end
      RUBY

      @plugin.write "app/helpers/engine_helper.rb", <<-RUBY
        module EngineHelper
          def help_the_engine
            "Helped."
          end
        end
      RUBY

      @plugin.write "app/controllers/bukkits/foo_controller.rb", <<-RUBY
        class Bukkits::FooController < ActionController::Base
          def index
            render :inline => "<%= help_the_engine %>"
          end

          def show
            render :text => foo_path
          end

          def from_app
            render :inline => "<%= (self.respond_to?(:bar_path) || self.respond_to?(:something)) %>"
          end

          def routes_helpers_in_view
            render :inline => "<%= foo_path %>, <%= app.bar_path %>"
          end
        end
      RUBY

      @plugin.write "app/mailers/bukkits/my_mailer.rb", <<-RUBY
        module Bukkits
          class MyMailer < ActionMailer::Base
          end
        end
      RUBY

      boot_rails

      assert_equal Bukkits._railtie, Bukkits::Engine
      assert ::Bukkits::MyMailer.method_defined?(:foo_path)
      assert !::Bukkits::MyMailer.method_defined?(:bar_path)

      env = Rack::MockRequest.env_for("/bukkits/from_app")
      response = AppTemplate::Application.call(env)
      assert_equal "false", response[2].body

      env = Rack::MockRequest.env_for("/bukkits/foo/show")
      response = AppTemplate::Application.call(env)
      assert_equal "/bukkits/foo", response[2].body

      env = Rack::MockRequest.env_for("/bukkits/foo")
      response = AppTemplate::Application.call(env)
      assert_equal "Helped.", response[2].body

      env = Rack::MockRequest.env_for("/bukkits/routes_helpers_in_view")
      response = AppTemplate::Application.call(env)
      assert_equal "/bukkits/foo, /bar", response[2].body
    end
  end
end
