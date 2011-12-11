require 'sinatra'
require 'haml'
require 'less'
require 'rack-flash'
require 'padrino-mailer'
require 'dm-pager'
require 'digest/md5'

require 'environment' # app/environment.rb



module ShareMatch
	class App < Sinatra::Base
		dir = File.dirname(File.expand_path(__FILE__))
		disable :run
		#disable :static
		set :root,     "#{dir}/.."
		set :public_folder,   "#{dir}/../public"
		set :app_file, __FILE__
		set :views,    "app/views"
		enable :sessions
		set :session_secret, "My session secret"#debug only, to work with shotgun
		use Mixpanel::Tracker::Middleware, "0f98554b168f38500e5264ec8afefe3b", :async => true
		use Rack::Flash
		register Padrino::Mailer


		APP_KEYS = YAML.load(File.open "config/keys.yml")

		set :delivery_method, :smtp => { 
			:address              => APP_KEYS['email']['address'],
			:port                 => APP_KEYS['email']['port'],
			:user_name            => APP_KEYS['email']['uname'],
			:password             => APP_KEYS['email']['pass'],
			:authentication       => :plain,
			:enable_starttls_auto => true  
		}

		before do
			@nav = Hash.new()
			@pills = Hash.new()
			@mixpanel = Mixpanel::Tracker.new("0f98554b168f38500e5264ec8afefe3b", request.env, true)

			@user = User.get( session[:user_id] ) if session[:user_id]
		end

		get '/' do
			@nav[:home] = 'active'
			haml :index
		end

		get '/item' do
			item_per_page = 12.0 #must be float for pages to be correctly calculated
			@nav[:find] = 'active'
			@page = 1
			@page = params[:page].to_i if params[:page]
			@pages = (Item.count / item_per_page).ceil

			if @page > @pages
				@page = @pages
			elsif @page < 1
				@page = 1
			end

			@items = Item.page @page, :per_page => item_per_page

			haml :'item/index'
		end

		get '/item/new' do
			login_required
			@nav[:share] = 'active'

			@item = Item.new

			haml :'item/create'
		end

		post '/item/new' do
			login_required
			params[:user_id] = @user.id
			@item = Item.new(params)
			if @item.valid?
				@item.save
				redirect "/item/#{@item.id}"
			else
				flash[:error] = "That item is not valid!"#TODO: improve this text
				redirect '/item/new'
			end
		end

		get '/item/:id' do |id|
			@item = Item.first(:id => id)
			if  @item.nil?
				haml :'404'
			else
				haml :'item/profile' 
			end
		end

		get '/item/:id/edit' do |id|
			login_required
			@nav[:share] = 'active'
			#TODO: should also check if the user is the right one!
			#very important!
			@item = Item.first(:id => id)
			haml :'item/edit'
		end

		post '/item/:id/edit' do |id|
			login_required
			#TODO: should also check if the user is the right one!
			#very important!
			#TODO: implement this
			flash[:error] = "Not yet implemented"
			@item = Item.first(:id => id)
			haml :'item/edit'
		end

		post '/item/:id' do |id|
			login_required
			@item = Item.first(:id => params[:item_id])
			@review = Review.new(:user => @user,
					     :item => @item,
					     :body => params['body'])
			if @review.valid?
				@review.save
			end

			redirect "/item/#{@item.id}"
		end


		get '/search' do
			@nav[:search] = 'active'
			haml :search
		end

		get '/sign-up' do
			@pills[:signup] = 'active'
			@step = 1
			@step = params[:step] if params[:step]

			# for debugging sign-up process, add &really=true to go to whichever step you want.
			unless params[:really]
				@step = 2 if params[:step] = 1 and @user
				@step = 3 if @user and @user.community
			end

			case @step.to_i
			when 1
				@user = User.new
			when 2
				self.login_required
				# Get the closest 20 communities
				@communities = @user.closest_communities
			when 3
				self.login_required
				@item = Item.new
			end

			@part = "signup/_step#{@step}"

			haml :'signup/signup'
		end

		post '/sign-up' do
			case params[:step] 
			when "1"
				params.delete("step")
				@a = User.new(params)
				if @a.valid?
					@a.save
					session[:user_id] = @a.id
					redirect '/sign-up?step=2'
				else
					flash[:error] = @a.errors.first
					redirect '/sign-up'
				end
			when "2"
				self.login_required
				@user.community_id = params[:community_id]
				if @user.save
					redirect '/sign-up?step=3'
				else
					flash[:error] = "Could not join community!"
					redirect '/sign-up?step=2'
				end
			end
		end

		get '/login' do
			@pills[:login] = 'active'
			haml :login
		end

		post '/login' do
			user = User.first(:email => params[:email])
			if not user.nil? and user.password_hash == params[:password]
				session[:user_id] = user.id
				redirect session[:before_path] || '/' 
			else
				flash[:forgot] = ''
				redirect '/login'
			end
		end

		post '/password-reset' do
			user = User.first(:email => params[:email])
			newpass = user.forgot_password
			#TODO: make this email less dumb
			email(:from => "reset@sharemat.ch", 
			      :to => user.email,
			      :subject => "Password Reset",
			      :body=>"Hi, we've given you a temporary password of #{newpass}. Login to reset.")
			flash[:sent] = ''
			redirect '/login'
		end
		post '/communities/new' do
			self.login_required
			c = Community.new(params)
			if c.valid? and c.save
				@user.community_id = c.id
				if @user.save
					# All went well!
					redirect '/sign-up?step=3'
				else
					flash[:error] = "Could not join community!"
					redirect '/sign-up?step=2'
				end
			else
				flash[:error] = "Could not create community!"
				redirect '/sign-up?step=2'
			end
		end

		get '/logout' do
			session[:user_id] = nil
			redirect '/'
		end

		get '/users/:id/edit' do #TODO: This shit is making Roy Fielding angry.  You won't like him when he's angry. 
			@nav[:user] = 'active'
			haml :"users/edit"
		end

		not_found do
			haml :'404'
		end

		helpers do 
			def signup_crumbs text, id, step
				retr = '<li'
				if  id == Integer(step)
					retr << ' class="active">'
					retr << text
				else
					retr << '>'
					retr << "<a href=\"/sign-up?step=#{id}\">"
					retr << text
					retr << '</a></li>'
				end
				return retr
			end

			def nav_li text, link, key
				el = "%li{:class=>\"#{key}\"}\n  %a{:href=>\"#{link}\"}#{text}
				"
				haml el
			end

			def login_required
				if session[:user_id]
					return true
				else
					session[:before_path] = request.path
					redirect '/login'
				end
			end

			def current_user
				User.get(session[:user_id])
			end

			def admin_required
				if session[:user_id] and User.get(session[:user_id]).is_admin?
					return true
				else
					return redirect '/login'
				end
			end

			def include_scripts
				scripts = Dir.glob("public/scripts/*.js").map{|path| path.slice!("public") ; path }
				out = ""
				scripts.each{ |file| out << "%script{:src=>\"#{file}\",:type=>\"text/javascript\"}\n" }
				haml out
			end

			def index_funnel card, text
				el = ".index-funnel\n  %a.btn.success.large.scrollPage{:href =>'#{card}'} #{text}"
				haml el
			end

			def gravatar user
				hash = Digest::MD5.hexdigest(user.email.downcase)
				"http://www.gravatar.com/avatar/#{hash}"
			end

		end
	end
end
