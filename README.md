Rack-Multisite
==============

Why Rack-Multisite Exists
-------------------------

The problem is this: I run a large number of very low-usage websites.
Therefore I don't want a large number of Thin instances hanging around, eating RAM but not doing very much otherwise.
Passenger is one option, but it's still aimed at improving performance rather than reducing resource-usage, and I've never got on with it particularly well.

Rack-multisite is an attempt to serve multiple sites using one Thin instance.
Unlike Rack's `map`, it routes based on domains, not URLs.
It also spawns each application instance in its own process (much like Shotgun), which means that the dependencies of one application don't start interfering with those of another (a particular issue with Bundler).

While this is all well and good, on its own it will increase overall RAM usage.
However, Rack-multisite will unload your application if it hasn't been called for a certain period of time, returning the RAM used to the system.
It will then restart the application when someone requests it.
In informal experiments, it reloads a simple Sinatra application in about half the time that Passenger takes.

It also allows for Passenger-style application reloading.
Instead of restarting Thin when you make changes to your site, just touch a file (default `tmp/restart.txt`), and Rack-multisite will reload your application on the next request.

Basic Usage
-----------

Imagine you have the following folder layout:

```
.
|-- multisite-controller
|   `-- config.ru
|-- app1
|   |-- config.ru
|   `-- app1.rb
`-- app2
    |-- config.ru
    `-- app2.rb
```

`app1` and `app2` are standalone applications, with their own `config.ru` files, such that you could `cd app1 && rackup`, and the application would start.
`multisite-controller/config.ru` is what we're interested in.

Inside `multisite-controller/config.ru`, do something similar to this:

```ruby
require 'rack/multisite'

run Rack::Multisite.new{
	map('domain1.tld', '../app1')
	map('domain2.tld', '../app2')
}
```

And that's it.
Running `cd rack-multisite && rackup` will launch Rack-multisite, which will load up `app1` and `app2` when you first request `domain1.tld` or `domain2.tld` respectively.

Advanced Usage
--------------

Now, there are of course more options available.

The `Rack::Multisite` constructor takes an array of options, with the following optional keys:

 - `:timeout`: The length of time, in seconds, that an application will idle for before shutting down.

Inside the block passed to the `Rack::Multisite` constructor, you can only call one method, `map`.
This method has the following prototype:

```ruby
map(domain, path, options={})
```

More detail on those arguments:

- `domain`: The domain which the application will be used to serve. It can either be a string, a regex, or the special value '*' (which matches if nothing else does, equivalent to `/.*/`).
- `path`: The path to the folder containing the application.
- `options`: A hash of the following optional arguments:
  - `:timeout`: This will override the timeout given to the `Rack::Multisite` constructor.
  - `:rackup_file`: The name of the rackup file, relative to `path`. Defaults to `config.ru`.
  - `:reload_file`: When the mtime of this file changes, the application will be reloaded. Defaults to `tmp/restart.txt`.
  - `:env`: A hash of parameters to be added to ENV, as seen by the application.

Putting this all together, we can come up with a more complex example:

```ruby
run Rack::Multisite.new(:timeout => 600){
	map(/.*domain1\.tld$/, '../app1', :reload_file => 'reload.txt', :env => {
		'DB_PASS' => '5up3r5ecr3t',
	})
	map('*', '../app2/', :timeout => 300, :rackup_file => 'my_rackup.ru')
}
```

Here, app1 will timeout after 600 seconds, its rackup file is at '../app1/config.ru', and its reload file at '../app1/reload.txt'.
Inside the application, `ENV['DB_PASS']` will be '5up3r5ecr3t'.

App2 will timeout after 300 seconds, its rackup file is at '../app2/my_rackup.ru', and its reload file at '../app2/tmp/restart.txt'.

Important Implications
----------------------

You will need to set `:session_secret` in your Sinatra app.
Otherwise, whenever the application is restarted, all sessions will die (as Sinatra generates a new session secret).

Caveats
-------

This is by no means polished software, and please, *please* don't use it for anything critical.
Due to the forking, it won't run under Windows.

Due to the piping going on, I strongly suspect that any asynchronous/eventmachine-y stuff will break it.

If it crashes badly, changes are it will freeze and refuse to exit.
In this case, a `pkill -9` is probably required.