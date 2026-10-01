import Host

## The program's environment variables.
##
## There's no way to set them: changing the environment while other threads
## may read it isn't safe. Pass settings to child code as arguments instead.
Env := [].{

	## The value of environment variable `name`. Fails with `VarNotFound` if
	## it isn't set, and with `VarNotUtf8` if its value isn't valid UTF-8;
	## each carries the name, so a message built from the error says which
	## variable it was.
	##
	## ```roc
	## port = Env.var!("PORT") ?? "8080"
	## ```
	var! : Str => Try(Str, [VarNotFound(Str), VarNotUtf8(Str)])
	var! = |name|
		match Host.env_var!(name) {
			Found(value) => Ok(value)
			Missing => Err(VarNotFound(name))
			NotUtf8 => Err(VarNotUtf8(name))
		}
}
