###
DocPad by Benjamin Lupton
Intuitive Web Development
###

# Requirements
fs = require 'fs'
path = require 'path'
sys = require 'util'
child_process = require 'child_process'

caterpillar = require 'caterpillar'
util = require 'bal-util'
EventSystem = util.EventSystem
_ = require 'underscore'

growl = null
express = null
watchr = null
queryEngine = null

PluginLoader = require "#{__dirname}/plugin-loader.coffee"
require "#{__dirname}/prototypes.coffee"

exec = (commands,options,callback) ->
	# Sync
	tasks = new util.Group callback
	
	# Tasks
	commands = [commands]  unless commands instanceof Array
	for command in commands
		tasks.push ((command) -> ->
			child_process.exec command, options, tasks.completer()
		)(command)

	# Execute the tasks synchronously
	tasks.sync()


# -------------------------------------
# DocPad

class DocPad extends EventSystem
	# Configurable
	config:
		# Plugins
		enableUnlistedPlugins: true,
		enabledPlugins:
			admin: false
			rest: false
		plugins: {}
		
		# Exchange
		exchange:
			# Skeletons
			skeletons:
				kitchensink:
					repo: 'https://github.com/bevry/kitchensink.docpad.git'
					description: 'A skeleton that includes everything'
				canvas:
					repo: 'https://github.com/bevry/canvas.docpad.git'
					description: 'A blank canvas for docpad'
			# Plugins
			plugins: {}
		
		# DocPad Paths
		corePath: "#{__dirname}/.."
		libPath: "#{__dirname}"
		mainPath: "#{__dirname}/docpad.coffee"
		pluginPath: "#{__dirname}/plugin.coffee"

		# Website Paths
		rootPath: null
		outPath: 'out'
		srcPath: 'src'
		layoutsPath: null
		documentsPath: null
		publicPath: null
		
		# Server
		server: null
		extendServer: true
		port: 9778
		maxAge: false

		# Logger
		logLevel: null
		logger: null
		growl: true
		checkVersion: true

	# DocPad
	version: null
	server: null
	logger: null
	templateData: {}

	# Models
	File: null
	Layout: null
	Document: null
	layouts: null
	documents: null
	
	# Plugins
	pluginsArray: []
	pluginsObject: {}


	# ---------------------------------
	# Main

	# Init
	constructor: (config={}) ->
		# Destruct prototype references
		@pluginsArray = []
		@pluginsObject = {}
		@templateData = {}

		# Apply configuration
		@loadConfiguration config, (err) ->
			# Error?
			return @error(err)  if err

			# Version Check
			docpad.compareVersion()
	
	# Load Configuration
	loadConfiguration: (userConfig={},next) ->
		# Prepare
		docpad = @
		logger = @logger

		# Exits
		fatal = (err) ->
			docpad.fatal(err,next)
		complete = (err) ->
			docpad.unblock 'generating, watching, serving', ->
				docpad.finish 'loading', ->
					next?(err)
		
		# Start loading
		docpad.start 'loading', (err) =>
			return fatal(err)  if err

			# Block other events
			docpad.block 'generating, watching, serving', (err) =>
				return fatal(err)  if err
					
				# Ensure essentials
				userConfig.corePath or= @config.corePath
				userConfig.rootPath or= process.cwd()

				# DocPad Configuration
				docpadPackagePath = "#{userConfig.corePath}/package.json"
				docpadPackageData = {}
				if path.existsSync docpadPackagePath
					try
						docpadPackageData = JSON.parse(fs.readFileSync(docpadPackagePath).toString()) or {}
					@version = docpadPackageData.version
				docpadPackageData.docpad or= {}
			
				# Website Configuration
				websitePackagePath = "#{userConfig.rootPath}/package.json"
				websitePackageData = {}
				if path.existsSync websitePackagePath
					try
						websitePackageData = JSON.parse(fs.readFileSync(websitePackagePath).toString()) or {}
				websitePackageData.docpad or= {}
				
				# Apply Configuration
				@config = _.extend(
					{}
					@config
					docpadPackageData.docpad
					websitePackageData.docpad
					userConfig
				)
				
				# Options
				@server = @config.server  if @config.server
				@config.rootPath = path.normalize(@config.rootPath or process.cwd())
				@config.outPath =
					if @config.outPath.indexOf('/') is -1  and  @config.outPath.indexOf('\\') is -1
						path.normalize("#{@config.rootPath}/#{@config.outPath}")
					else
						path.normalize(@config.outPath)
				@config.srcPath = 
					if @config.srcPath.indexOf('/') is -1  and  @config.srcPath.indexOf('\\') is -1
						path.normalize("#{@config.rootPath}/#{@config.srcPath}")
					else
						path.normalize(@config.srcPath)
				@config.layoutsPath = "#{@config.srcPath}/layouts"
				@config.documentsPath = "#{@config.srcPath}/documents"
				@config.publicPath = "#{@config.srcPath}/public"

				# Logger
				unless @config.logLevel?
					@config.logLevel = if process.argv.has('-d') then 7 else 6
				@logger = @config.logger or= new caterpillar.Logger
					transports:
						level: @config.logLevel
						formatter:
							module: module
				
				# Bind the error handler, so we don't crash on errors
				process.on 'uncaughtException', (err) ->
					docpad.error err

				# Prepare enabled plugins
				if typeof @config.enabledPlugins is 'string'
					enabledPlugins = {}
					for enabledPlugin in @config.enabledPlugins.split(/[ ,]+/)
						enabledPlugins[enabledPlugin] = true
					@config.enabledPlugins = enabledPlugins
				
				# Load Plugins
				docpad.loadPlugins (err) ->
					return complete(err)  if err
					docpad.unblock 'generating, watching, serving', (err) ->
						return complete(err)  if err
						docpad.finish 'loading', (err) ->
							return complete(err)  if err

	# Create snore
	createSnore: (message) ->
		# Prepare
		logger = @logger

		# Create snore object
		snore =
			snoring: false
			timer: setTimeout(
				->
					snore.clear()
					snore.snoring = true
					logger.log 'notice', message
				5000
			)
			clear: ->
				if snore.timer
					clearTimeout(snore.timer)
					snore.timer = false

	# Layout Document
	createDocument: (meta={}) ->
		# Prepare
		config =
			docpad: @
			layouts: @layouts
			logger: @logger
			meta: meta
		
		# Create and return
		document = new @Document config
	
	# Create Layout
	createLayout: (meta={}) ->
		# Prepare
		config =
			docpad: @
			layouts: @layouts
			logger: @logger
			meta: meta

		# Create and return
		layout = new @Layout config

	# Clean Models
	cleanModels: (next) ->
		# Prepare
		File = @File = require("#{@config.libPath}/file.coffee")
		Layout = @Layout = class extends File
		Document = @Document = class extends File
		layouts = @layouts = new queryEngine.Collection
		documents = @documents = new queryEngine.Collection
		
		# Extend
		Layout::store = ->
			layouts[@id] = @
		Document::store = ->
			documents[@id] = @
		
		# Next
		next?()

		# Chain
		@

	# Compare versions
	compareVersion: ->
		return @  unless @config.checkVersion

		# Prepare
		notify = @notify
		logger = @logger

		# Check
		util.packageCompare
			local: "#{@config.corePath}/package.json"
			remote: 'https://raw.github.com/bevry/docpad/master/package.json'
			newVersionCallback: (details) ->
				docpad.notify 'There is a new version of docpad available'
				docpad.logger.log 'notice', """
					There is a new version of docpad available, you should probably upgrade...
					current version:  #{details.local.version}
					new version:      #{details.remote.version}
					grab it here:     #{details.remote.homepage}
					"""
		@

	# Initialise the Skeleton
	initializeSkeleton: (skeleton, destinationPath, next) ->
		# Prepare
		docpad = @
		logger = @logger
		skeletonRepo = @config.skeletons[skeleton].repo
		logger.log 'info', "[#{skeleton}] Initialising the Skeleton to #{destinationPath}"
		snore = @createSnore "[#{skeleton}] This could take a while, grab a snickers"

		# Async
		tasks = new util.Group (err) ->
			snore.clear()
			logger.log 'info', "[#{skeleton}] Initialised the Skeleton"  unless err
			next?(err)
		tasks.total = 2
		
		# Pull
		logger.log 'debug', "[#{skeleton}] Pulling in the Skeleton"
		child = exec(
			# Commands
			[
				"git init"
				"git remote add skeleton #{skeletonRepo}"
				"git pull skeleton master"
			]
			
			# Options
			{
				cwd: destinationPath
			}

			# Next
			(err,stdout,stderr) ->
				# Output
				if err
					console.log stdout.replace(/\s+$/,'')  if stdout
					console.log stderr.replace(/\s+$/,'')  if stderr
					return next?(err)
				
				# Log
				logger.log 'debug', "[#{skeleton}] Pulled in the Skeleton"

				# Submodules
				path.exists "#{destinationPath}/.gitmodules", (exists) ->
					tasks.complete()  unless exists
					logger.log 'debug', "[#{skeleton}] Initialising Submodules for Skeleton"
					child = exec(
						# Commands
						[
							'git submodule init'
							'git submodule update'
							'git submodule foreach --recursive "git init"'
							'git submodule foreach --recursive "git checkout master"'
							'git submodule foreach --recursive "git submodule init"'
							'git submodule foreach --recursive "git submodule update"'
						]
						
						# Options
						{
							cwd: destinationPath
						}

						# Next
						(err,stdout,stderr) ->
							# Output
							if err
								console.log stdout.replace(/\s+$/,'')  if stdout
								console.log stderr.replace(/\s+$/,'')  if stderr
								return tasks.complete(err)  
							
							# Complete
							logger.log 'debug', "[#{skeleton}] Initalised Submodules for Skeleton"
							tasks.complete()
					)
				
				# NPM
				path.exists "#{destinationPath}/package.json", (exists) ->
					tasks.complete()  unless exists
					logger.log 'debug', "[#{skeleton}] Initialising NPM for Skeleton"
					child = exec(
						# Command
						'npm install'

						# Options
						{
							cwd: destinationPath
						}

						# Next
						(err,stdout,stderr) ->
							# Output
							if err
								console.log stdout.replace(/\s+$/,'')  if stdout
								console.log stderr.replace(/\s+$/,'')  if stderr
								return tasks.complete(err)  
							
							# Complete
							logger.log 'debug', "[#{skeleton}] Initialised NPM for Skeleton"
							tasks.complete()
					)
		)

		# Chain
		@
	
	# Handle
	action: (action,next) ->
		# Multiple actions?
		actions = action.split ' '
		if actions.length > 1
			tasks = new util.Group next
			tasks.total = actions.length
			for action in actions
				@action action, tasks.completer()
			return @
		
		# Handle
		switch action
			when 'skeleton', 'scaffold'
				@skeletonAction (err) =>
					return @error(err)  if err
					next?()

			when 'generate'
				@generateAction (err) =>
					return @error(err)  if err
					next?()

			when 'watch'
				@watchAction (err) =>
					return @error(err)  if err
					next?()

			when 'server', 'serve'
				@serverAction (err) =>
					return @error(err)  if err
					next?()

			else
				@skeletonAction (err) =>
					return @error(err)  if err
					@generateAction (err) =>
						return @error(err)  if err
						@serverAction (err) =>
							return @error(err)  if err
							@watchAction (err) =>
								return @error(err)  if err
								next?()
		
		# Chain
		@
	

	# Create a next wrapper
	createNextWrapper: (next) ->
		return (args...) =>
			@error(args[0])  if args[0]
			next.apply(next,apply)  if typeof next is 'function'
	
	# Handle a fatal error
	fatal: (err) ->
		return @  unless err
		@error(error)
		process.exit(-1)

	# Handle an error
	error: (err,type='err') ->
		return @  unless err
		err = new Error(err)  unless err instanceof Err
		@logger.log type, 'An error occured:', err.message, err.stack
		@

	# Perform a growl notification
	notify: (args...) =>
		return @  unless @config.growl
		growl = require('growl')  unless growl
		growl.apply(growl,args)
		@



	# ---------------------------------
	# Plugins


	# Get a plugin by it's name
	getPlugin: (pluginName) ->
		@pluginsObject[pluginName]

	# Trigger a plugin event
	# next?(err)
	triggerEvent: (eventName,data,next) ->
		# Prepare
		data or= data
		data.logger = @logger
		data.docpad = @

		# Trigger
		@cycle eventName, data, next

		# Chain
		@

	# Load Plugins
	loadPlugins: (next) ->
		# Prepare
		logger = @logger
		docpad = @
		snore = @createSnore "We're preparing your plugins, this may take a while the first time. Perhaps grab a snickers?"

		# Async
		tasks = new util.Group (err) ->
			snore.clear()
			return next?(err)  if err
			logger.log 'debug', 'All plugins loaded'
			next?(err)
		
		# Load in the docpad and local plugin directories
		tasks.push => @loadPluginsIn "#{@config.libPath}/plugins", tasks.completer()
		if @config.rootPath isnt __dirname and path.existsSync "#{@config.rootPath}/plugins"
			tasks.push => @loadPluginsIn "#{@config.rootPath}/plugins", tasks.completer()
		
		# Execute the loading asynchronously
		tasks.async()

		# Chain
		@

	# Load Plugins
	loadPluginsIn: (pluginsPath, next) ->
		# Prepare
		logger = @logger
		docpad = @

		# Load Plugins
		logger.log 'debug', "Plugins loading for #{pluginsPath}"
		util.scandir(
			# Path
			pluginsPath,

			# Skip files
			false,

			# Handle directories
			(fileFullPath,fileRelativePath,_nextFile) =>
				# Prepare
				return nextFile(null,false)  if fileFullPath is pluginsPath
				nextFile = (err,skip) =>
					if err
						logger.log 'warn', "Failed to load the plugin #{loader.pluginName} at #{fileFullPath}. The error follows"
						@error err, 'warn'
					_nextFile(null,skip)

				# Prepare
				loader = new PluginLoader dirPath: fileFullPath, docpad: docpad
				pluginName = loader.pluginName
				enabled = (
					(@config.enableUnlistedPlugins  and  @config.enabledPlugins[pluginName]? is false)  or
					@config.enabledPlugins[pluginName] is true
				)

				# Check
				unless enabled
					# Skip
					logger.log 'debug', "Skipping plugin #{pluginName}"
					return nextFile(null,true)
				else
					# Load
					logger.log 'debug', "Loading plugin #{pluginName}"
					loader.exists (err,exists) =>
						return nextFile(err,true)  if err or not exists
						loader.install (err) =>
							return nextFile(err,true)  if err
							loader.require (err) =>
								return nextFile(err,true)  if err
								loader.create {}, (err,pluginInstance) =>
									return nextFile(err,true)  if err
									@pluginsObject[loader.pluginName] = pluginInstance
									@pluginsArray.push pluginInstance
									logger.log 'debug', "Loaded plugin #{pluginName}"
									return nextFile(null,true)
				
			# Next
			(err) =>
				@pluginsArray.sort (a,b) -> a.priority - b.priority
				logger.log 'debug', "Plugins loaded for #{pluginsPath}"
				next?(err)
		)
	
		# Chain
		@


	# ---------------------------------
	# Actions

	# Clean the database
	generateClean: (next) ->
		# Before
		@triggerEvent 'cleanBefore', {}, (err) =>
			return next?(err)  if err

			# Prepare
			docpad = @
			logger = @logger
			logger.log 'debug', 'Cleaning started'

			# Models
			@cleanModels()
			
			# Async
			tasks = new util.Group (err) ->
				# After
				docpad.triggerEvent 'cleanAfter', {}, (err) ->
					logger.log 'debug', 'Cleaning finished'  unless err
					next?(err)
			tasks.total = 6

			# Files
			util.rmdir @config.outPath, (err,list,tree) ->
				logger.log 'debug', 'Cleaned files'  unless err
				tasks.complete err

			# Layouts
			@layouts.remove {}, (err) ->
				logger.log 'debug', 'Cleaned layouts'  unless err
				tasks.complete err
			
			# Documents
			@documents.remove {}, (err) ->
				logger.log 'debug', 'Cleaned documents'  unless err
				tasks.complete err
			
			# Ensure Layouts
			util.ensurePath @config.layoutsPath, (err) ->
				logger.log 'debug', 'Ensured layouts'  unless err
				tasks.complete err
			
			# Ensure Documents
			util.ensurePath @config.documentsPath, (err) ->
				logger.log 'debug', 'Ensured documents'  unless err
				tasks.complete err
		
			# Ensure Public
			util.ensurePath @config.publicPath, (err) ->
				logger.log 'debug', 'Ensured public'  unless err
				tasks.complete err
		
		# Chain
		@

	# Check if the file path is ignored
	# next?(err,ignore)
	filePathIgnored: (fileFullPath,next) ->
		if path.basename(fileFullPath).startsWith('.') or path.basename(fileFullPath).finishesWith('~')
			next?(null, true)
		else
			next?(null, false)
		
		# Chain
		@

	# Parse the files
	generateParse: (next) ->
		# Before
		@triggerEvent 'parseBefore', {}, (err) =>
			return next?(err)  if err

			# Requires
			docpad = @
			logger = @logger
			logger.log 'debug', 'Parsing files'

			# Async
			tasks = new util.Group (err) ->
				# Check
				return next?(err)  if err
				# Contextualize
				docpad.generateParseContextualize (err) ->
					return next?(err)  if err
					# After
					docpad.triggerEvent 'parseAfter', {}, (err) ->
						logger.log 'debug', 'Parsed files'  unless err
						next?(err)
			
			# Tasks
			tasks.total = 2

			# Layouts
			util.scandir(
				# Path
				@config.layoutsPath,

				# File Action
				(fileFullPath,fileRelativePath,nextFile) ->
					# Ignore?
					docpad.filePathIgnored fileFullPath, (err,ignore) ->
						return nextFile(err)  if err or ignore
						layout = docpad.createLayout(
								fullPath: fileFullPath
								relativePath: fileRelativePath
						)
						layout.load (err) ->
							return nextFile(err)  if err
							layout.store()
							nextFile err
					
				# Dir Action
				null,

				# Next
				(err) ->
					logger.log 'warn', 'Failed to parse layouts', err  if err
					tasks.complete err
			)

			# Documents
			util.scandir(
				# Path
				@config.documentsPath,

				# File Action
				(fileFullPath,fileRelativePath,nextFile) ->
					# Ignore?
					docpad.filePathIgnored fileFullPath, (err,ignore) ->
						return nextFile(err)  if err or ignore
						document = docpad.createDocument(
							fullPath: fileFullPath
							relativePath: fileRelativePath
						)
						document.load (err) ->
							return nextFile err  if err

							# Ignored?
							if document.ignore or document.ignored or document.skip or document.published is false or document.draft is true
								logger.log 'info', 'Skipped manually ignored document:', document.relativePath
								return nextFile()
							
							# Store Document
							document.store()
							nextFile err
				
				# Dir Action
				null,

				# Next
				(err) ->
					logger.log 'warn', 'Failed to parse documents', err  if err
					tasks.complete err
			)

		# Chain
		@
	
	# Generate Parse: Contextualize
	generateParseContextualize: (next) ->
		# Prepare
		docpad = @
		logger = @logger
		logger.log 'debug', 'Parsing files: Contextualizing files'

		# Async
		tasks = new util.Group (err) ->
			return next?(err)  if err
			logger.log 'debug', 'Parsing files: Contextualized files'
			next?()
		
		# Fetch
		documents = @documents.find({}).sort({'date':-1})
		return tasks.exit()  unless documents.length
		tasks.total += documents.length

		# Scan all documents
		documents.forEach (document) ->
			document.contextualize tasks.completer()

		# Chain
		@
	
	# Render a document
	render: (document,data,next) ->
		templateData = _.extend {}, @templateData, data
		templateData.document = document
		document.render templateData, (err) =>
			@error err  if err
			next?()

	# Generate render
	generateRender: (next) ->
		# Prepare
		docpad = @
		logger = @logger
		logger.log 'debug', 'Rendering files'

		# Async
		tasks = new util.Group (err) ->
			return next?(err)  if err
			# After
			docpad.triggerEvent 'renderAfter', {}, (err) ->
				logger.log 'debug', 'Rendered files'  unless err
				next?(err)
		
		# Prepare template data
		documents = @documents.find({}).sort('date': -1)
		return tasks.exit()  unless documents.length
		@templateData =
			require: require
			docpad: @
			documents: documents
			database: @documents
			document: null
			site:
				date: new Date()
			blocks:
				scripts: []
				styles: []

		# Before
		@triggerEvent 'renderBefore', {documents,@templateData}, (err) =>
			return next?(err)  if err
			# Render documents
			tasks.total += documents.length
			documents.forEach (document) =>
				return tasks.complete()  if document.dynamic
				@render document, {}, tasks.completer()

		# Chain
		@

	# Write files
	generateWriteFiles: (next) ->
		# Prepare
		logger = @logger
		logger.log 'debug', 'Writing files'

		# Write
		util.cpdir(
			# Src Path
			@config.publicPath,
			# Out Path
			@config.outPath
			# Next
			(err) ->
				logger.log 'debug', 'Wrote files'  unless err
				next?(err)
		)

		# Chain
		@

	# Write documents
	generateWriteDocuments: (next) ->
		# Prepare
		logger = @logger
		outPath = @config.outPath
		logger.log 'debug', 'Writing documents'

		# Async
		tasks = new util.Group (err) ->
			logger.log 'debug', 'Wrote documents'  unless err
			next?(err)

		# Find documents
		@documents.find {}, (err,documents,length) ->
			# Error
			return tasks.exit err  if err
			return tasks.exit()  unless length

			# Cycle
			tasks.total += length
			documents.forEach (document) ->
				# Dynamic
				return tasks.complete()  if document.dynamic

				# OutPath
				document.outPath = "#{outPath}/#{document.url}"
				
				# Ensure path
				util.ensurePath path.dirname(document.outPath), (err) ->
					# Error
					return tasks.exit err  if err

					# Write document
					logger.log 'debug', "Writing file #{document.relativePath}, #{document.url}"
					fs.writeFile document.outPath, document.contentRendered, (err) ->
						tasks.complete err

		# Chain
		@

	# Write
	generateWrite: (next) ->
		# Prepare
		docpad = @
		logger = @logger

		# Before
		docpad.triggerPluginEvent 'writeBefore', {}, (err) ->
			return next?(err)  if err
			logger.log 'debug', 'Writing everything'

			# Async
			tasks = new util.Group (err) ->
				return next?(err)  if err
				# After
				docpad.triggerEvent 'writeAfter', {}, (err) ->
					logger.log 'debug', 'Wrote everything'  unless err
					next?(err)
			tasks.total = 2

			# Files
			docpad.generateWriteFiles tasks.completer()
			
			# Documents
			docpad.generateWriteDocuments tasks.completer()

		# Chain
		@

	# Generate
	generateAction: (next) ->
		# Prepare
		docpad = @
		logger = @logger
		notify = @notify
		queryEngine = require('query-engine')  unless queryEngine

		# Exits
		fatal = (err) ->
			docpad.fatal(err,next)
		complete = (err) ->
			docpad.unblock 'loading', ->
				docpad.finish 'generating', ->
					next?(err)
		
		# Block loading
		docpad.block 'loading', (err) ->
			return fatal(err)  if err
			# Start generating
			docpad.start 'generating', (err) =>
				return fatal(err)  if err
				logger.log 'info', 'Generating...'
				# Plugins
				docpad.triggerPluginEvent 'serverBefore', server: docpad.server, (err) ->
					return complete(err)  if err
					# Continue
					path.exists docpad.config.srcPath, (exists) ->
						# Check
						if exists is false
							return complete new Error 'Cannot generate website as the src dir was not found'
						# Generate Clean
						docpad.generateClean (err) ->
							return complete(err)  if err
							# Generate Parse
							docpad.generateParse (err) ->
								return complete(err)  if err
								# Generate Render (First Pass)
								docpad.generateRender (err) ->
									return complete(err)  if err
									# Generate Render (Second Pass)
									docpad.generateRender (err) ->
										return complete(err)  if err
										# Generate Write
										docpad.generateWrite (err) ->
											return complete(err)  if err
											# Unblock
											docpad.unblock 'loading', (err) ->
												return complete(err)  if err	
												# Plugins
												docpad.triggerPluginEvent 'serverAfter', server: docpad.server, (err) ->
													return complete(err)  if err
													# Finished
													docpad.finished 'generating', (err) ->
														return complete(err)  if err
														# Generated
														logger.log 'info', 'Generated'
														notify (new Date()).toLocaleTimeString(), title: 'Website Generated'
														# Completed
														complete()

		# Chain
		@

	# Watch
	# NOTE: Watching a directory and all it's contents (including subdirs and their contents) appears to be quite expiremental in node.js - if you know of a watching library that is quite stable, then please let me know - b@lupton.cc
	watchAction: (next) ->
		# Prepare
		docpad = @
		logger = @logger
		watchr = require('watchr')  unless watchr

		# Exits
		fatal = (err) ->
			docpad.fatal(err,next)
		complete = (err) ->
			docpad.unblock 'loading', ->
				docpad.finish 'watching', ->
					next?(err)
		
		# Block loading
		docpad.block 'loading', (err) ->
			return next?(err)  if err
			docpad.start 'watching', (err) ->
				# Prepare
				logger.log 'Watching setup starting...'

				# Watch the source directory
				watchr.watch docpad.config.srcPath, ->
					docpad.action 'generated', (err) ->
						docpad.error(err)  if err
						logger.log 'Regenerated due to file watch at '+(new Date()).toLocaleString()
				
				# Unwatch if loaded
				docpad.once 'loading:started', (err) ->
					return fatal(err)  if err
					# Unwatch the source directory
					watchr.unwatch docpad.config.srcPath

				# Completed
				logger.log 'Watching setup'
				complete()
		
		# Chain
		@

	# Skeleton
	skeletonAction: (next) ->
		# Prepare
		docpad = @
		logger = @logger
		skeleton = @config.skeleton
		destinationPath = @config.rootPath

		# Exits
		fatal = (err) ->
			docpad.fatal(err,next)
		complete = (err) ->
			docpad.unblock 'loading', ->
				docpad.finish 'skeleton', ->
					next?(err)

		# Block loading
		docpad.block 'loading', (err) ->
			return fatal(err)  if err
			docpad.start 'skeleton', (err) ->
				return fatal(err)  if err
				# Copy
				path.exists docpad.config.srcPath, (exists) ->
					# Check
					if exists
						logger.log 'notice', 'Cannot place skeleton as the desired structure already exists'
						return complete()
					
					# Initialise Skeleton
					logger.log 'info', "About to initialize the skeleton [#{skeleton}] to [#{destinationPath}]"
					docpad.initializeSkeleton skeleton, destinationPath, (err) ->
						return complete(err)

		# Chain
		@

	# Server
	serverAction: (next) ->
		# Prepare
		docpad = @
		logger = @logger
		config = @config
		express = require 'express'  unless express

		# Exists
		fatal = (err) ->
			docpad.fatal(err,next)
		complete = (err) ->
			docpad.unblock 'loading', (err) ->
				return next?(err)  if err
				docpad.finish 'serving', (err) ->
					return next?(err)  if err
					next?()
		
		# Block loading
		docpad.block 'loading', (err) ->
			return fatal(err)  if err
			docpad.start 'serving', (err) ->
				return fatal(err)  if err
				# Plugins
				docpad.triggerPluginEvent 'serverAfter', {}, (err) ->
					return next?(err)  if err

					# Server
					server = docpad.server = express.createServer()  unless docpad.server

					# Extend the server
					if config.extendServer
						# Configure the server
						server.configure ->
							# POST Middleware
							server.use express.bodyParser()
							server.use express.methodOverride()

							# DocPad Header
							server.use (req,res,next) ->
								tools = res.header('X-Powered-By').split /[,\s]+/g
								tools.push 'DocPad'
								tools = tools.join(',')
								res.header('X-Powered-By',tools)

							# Router Middleware
							server.use server.router

							# Routing
							server.use (req,res,next) ->
								return next?()  unless docpad.documents
								cleanUrl = req.url.replace(/\?.*/,'')
								docpad.documents.findOne {urls:{'$in':cleanUrl}}, (err,document) =>
									if err
										docpad.error err
										res.send(err.message, 500)
									else if document
										res.contentType(document.outPath or document.url)
										if document.dynamic
											docpad.render document, req: req, (err) =>
												if err
													docpad.error err
													res.send(err.message, 500)
												else
													res.send(document.contentRendered)
										else
											res.send(document.contentRendered)
									else
										next?()

							# Static
							if config.maxAge
								server.use express.static config.outPath, maxAge: config.maxAge
							else
								server.use express.static config.outPath
							
							# 404 Middleware
							server.use (req,res,next) ->
								res.send(404)
						
						# Start the server
						result = server.listen config.port
						try
							logger.log 'info', 'Web server listening on port', server.address().port, 'on directory', config.outPath
						catch err
							logger.log 'err', "Could not start the web server, chances are the desired port #{config.port} is already in use"
					
					# Plugins
					triggerPluginEvent 'serverAfter', {server}, (err) ->
						return complete(err)  if err
						# Complete
						logger.log 'debug', 'Server setup'  unless err
						complete()

		# Chain
		@

# API
docpad =
	DocPad: DocPad
	createInstance: (config) ->
		return new DocPad(config)

# Export
module.exports = docpad
