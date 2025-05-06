"""
Multirun is a rule for running multiple commands in a single invocation. This
can be very useful for something like running multiple linters or formatters
in a single invocation.
"""
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@bazel_skylib//lib:shell.bzl", "shell")
load(
    "//internal:constants.bzl",
    "CommandInfo",
    "RUNFILES_PREFIX",
    "rlocation_path",
    "update_attrs",
)
load("//internal:runfiles_enabled.bzl", "RunfilesEnabledProvider")

_SH_TOOLCHAIN_TYPE = Label("@rules_shell//shell:toolchain_type")
_RUNFILES_ENABLED_LABEL = Label("//:runfiles_enabled")

_BinaryArgsEnvInfo = provider(
    fields = ["args", "env"],
    doc = "The arguments and environment to use when running the binary",
)

def _binary_args_env_aspect_impl(target, ctx):
    if _BinaryArgsEnvInfo in target:
        return []

    is_executable = target.files_to_run != None and target.files_to_run.executable != None
    args = getattr(ctx.rule.attr, "args", [])
    env = getattr(ctx.rule.attr, "env", {})

    if is_executable and (args or env):
        expansion_targets = getattr(ctx.rule.attr, "data", [])
        if expansion_targets:
            args = [
                ctx.expand_location(arg, expansion_targets)
                for arg in args
            ]
            env = {
                name: ctx.expand_location(val, expansion_targets)
                for name, val in env.items()
            }
        return [_BinaryArgsEnvInfo(args = args, env = env)]

    return []

_binary_args_env_aspect = aspect(
    implementation = _binary_args_env_aspect_impl,
)


_WINDOWS_EXECUTABLE_EXTENSIONS = [
    "exe",
    "cmd",
    "bat",
]

def _is_windows_executable(file):
    return file.extension in _WINDOWS_EXECUTABLE_EXTENSIONS

def _create_windows_exe_launcher(ctx, sh_toolchain, primary_output):
    if not sh_toolchain.launcher or not sh_toolchain.launcher_maker:
        fail("Windows sh_toolchain requires both 'launcher' and 'launcher_maker' to be set")

    bash_launcher = ctx.actions.declare_file(ctx.label.name + ".exe")

    launch_info = ctx.actions.args().use_param_file("%s", use_always = True).set_param_file_format("multiline")
    launch_info.add("binary_type=Bash")
    launch_info.add(ctx.workspace_name, format = "workspace_name=%s")
    launch_info.add("1" if ctx.attr._runfiles_enabled[RunfilesEnabledProvider].runfiles_enabled else "0", format = "symlink_runfiles_enabled=%s")
    launch_info.add(sh_toolchain.path, format = "bash_bin_path=%s")
    bash_file_short_path = primary_output.short_path
    if bash_file_short_path.startswith("../"):
        bash_file_rlocationpath = bash_file_short_path[3:]
    else:
        bash_file_rlocationpath = ctx.workspace_name + "/" + bash_file_short_path
    launch_info.add(bash_file_rlocationpath, format = "bash_file_rlocationpath=%s")

    launcher_artifact = sh_toolchain.launcher
    ctx.actions.run(
        executable = sh_toolchain.launcher_maker,
        inputs = [launcher_artifact],
        outputs = [bash_launcher],
        arguments = [launcher_artifact.path, launch_info, bash_launcher.path],
        use_default_shell_env = True,
        toolchain = _SH_TOOLCHAIN_TYPE,
    )
    return bash_launcher

def _launcher_for_windows(ctx, primary_output, main_file):
    if _is_windows_executable(main_file):
        if main_file.extension == primary_output.extension:
            return primary_output
        else:
            fail("Source file is a Windows executable file, target name extension should match source file extension")

    # bazel_tools should always registers a toolchain for Windows, but it may have an empty path.
    sh_toolchain = ctx.toolchains[_SH_TOOLCHAIN_TYPE]
    if not sh_toolchain or not sh_toolchain.path:
        # Let fail print the toolchain type with an apparent repo name.
        fail(
            """No suitable shell toolchain found:
* if you are running Bazel on Windows, set the BAZEL_SH environment variable to the path of bash.exe
* if you are running Bazel on a non-Windows platform but are targeting Windows, register an sh_toolchain for the""",
            _SH_TOOLCHAIN_TYPE,
            "toolchain type",
        )

    return _create_windows_exe_launcher(ctx, sh_toolchain, primary_output)

def _multirun_impl(ctx):
    instructions_file = ctx.actions.declare_file(ctx.label.name + ".json")
    runner_info = ctx.attr._runner[DefaultInfo]
    runner_exe = runner_info.files_to_run.executable

    runfiles = ctx.runfiles(files = [instructions_file, runner_exe])
    runfiles = runfiles.merge(ctx.attr._bash_runfiles[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(runner_info.default_runfiles)

    for data_dep in ctx.attr.data:
        default_runfiles = data_dep[DefaultInfo].default_runfiles
        if default_runfiles != None:
            runfiles = runfiles.merge(default_runfiles)

    commands = []
    tagged_commands = []
    runfiles_files = []
    for command in ctx.attr.commands:
        tagged_commands.append(struct(tag = str(command.label), command = command))

    for tag_command in tagged_commands:
        command = tag_command.command

        default_info = command[DefaultInfo]
        if default_info.files_to_run == None:
            fail("%s is not executable" % command.label, attr = "commands")
        exe = default_info.files_to_run.executable
        if exe == None:
            fail("%s does not have an executable file" % command.label, attr = "commands")
        runfiles_files.append(exe)

        args = []
        env = {}
        if _BinaryArgsEnvInfo in command:
            args = command[_BinaryArgsEnvInfo].args
            env = command[_BinaryArgsEnvInfo].env

        default_runfiles = default_info.default_runfiles
        if default_runfiles != None:
            runfiles = runfiles.merge(default_runfiles)

        if CommandInfo in command:
            tag = command[CommandInfo].description
        else:
            tag = "Running {}".format(tag_command.tag)

        commands.append(struct(
            tag = tag,
            path = exe.short_path,
            args = args,
            env = env,
        ))

    if ctx.attr.jobs < 0:
        fail("'jobs' attribute should be at least 0")
    elif ctx.attr.jobs > 0 and ctx.attr.forward_stdin:
        fail("'forward_stdin' can only apply to parallel jobs ('jobs' === 0)")

    jobs = ctx.attr.jobs
    instructions = struct(
        commands = commands,
        jobs = jobs,
        print_command = ctx.attr.print_command,
        keep_going = ctx.attr.keep_going,
        buffer_output = ctx.attr.buffer_output,
        forward_stdin = ctx.attr.forward_stdin,
        workspace_name = ctx.workspace_name,
    )
    ctx.actions.write(
        output = instructions_file,
        content = json.encode(instructions),
    )

    script = """\
multirun_script="$(rlocation {})"
instructions="$(rlocation {})"
exec "$multirun_script" "$instructions" "$@"
""".format(shell.quote(rlocation_path(ctx, runner_exe)), shell.quote(rlocation_path(ctx, instructions_file)))
    out_file = ctx.actions.declare_file(ctx.label.name + ".bash")
    ctx.actions.write(
        output = out_file,
        content = RUNFILES_PREFIX + script,
        is_executable = True,
    )

    direct_files = [instructions_file, out_file]

    
    if ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]):
        main_executable = _launcher_for_windows(ctx, out_file, out_file)
        direct_files.append(main_executable)
    else:
        main_executable = out_file
    
    files = depset(direct=direct_files)
    return [
        DefaultInfo(
            files = files,
            runfiles = runfiles.merge(ctx.runfiles(transitive_files = files, files = runfiles_files + ctx.files.data, collect_default = True)),
            executable = main_executable,
        ),
    ]

def multirun_with_transition(cfg, allowlist = None):
    """Creates a multirun rule which transitions all commands to the given configuration.

    This is useful if you have a project-specific configuration that you want
    to apply to all of your commands. See also command_with_transition.

    Args:
        cfg: The transition to force on the dependent commands.
        allowlist: The transition allowlist to use for the given cfg. Not necessary in newer bazel versions.
    """
    attrs = {
        "commands": attr.label_list(
            mandatory = False,
            allow_files = True,
            aspects = [_binary_args_env_aspect],
            doc = "Targets to run",
            cfg = cfg,
        ),
        "data": attr.label_list(
            doc = "The list of files needed by the commands at runtime. See general comments about `data` at https://docs.bazel.build/versions/master/be/common-definitions.html#common-attributes",
            allow_files = True,
        ),
        "jobs": attr.int(
            default = 1,
            doc = "The expected concurrency of targets to be executed. Default is set to 1 which means sequential execution. Setting to 0 means that there is no limit concurrency.",
        ),
        "print_command": attr.bool(
            default = True,
            doc = "Print what command is being run before running it.",
        ),
        "keep_going": attr.bool(
            default = False,
            doc = "Keep going after a command fails. Only for sequential execution.",
        ),
        "buffer_output": attr.bool(
            default = False,
            doc = "Buffer the output of the commands and print it after each command has finished. Only for parallel execution.",
        ),
        "forward_stdin": attr.bool(
            default = False,
            doc = "Whether or not to forward stdin",
        ),
        "_windows_constraint": attr.label(
            default = "@platforms//os:windows",
        ),
        "_runfiles_enabled": attr.label(
            default = _RUNFILES_ENABLED_LABEL,
            providers = [RunfilesEnabledProvider],
        ),
        "_bash_runfiles": attr.label(
            default = Label("@bazel_tools//tools/bash/runfiles"),
        ),
        "_runner": attr.label(
            default = Label("//internal:multirun"),
            cfg = "exec",
            executable = True,
        ),
    }

    return rule(
        implementation = _multirun_impl,
        attrs = update_attrs(attrs, cfg, allowlist),
        toolchains = [
            config_common.toolchain_type(_SH_TOOLCHAIN_TYPE, mandatory = False),
        ],
        executable = True,
        doc = """\
A multirun composes multiple command rules in order to run them in a single
bazel invocation, optionally in parallel. This can have a major performance
improvement both in build time and run time depending on your tools.

```bzl
load("@rules_multirun//:defs.bzl", "command", "multirun")
load("@rules_python//python:defs.bzl", "py_binary")

sh_binary(
    name = "some_linter",
    ...
)

py_binary(
    name = "some_other_linter",
    ...
)

command(
    name = "lint-something",
    command = ":some_linter",
    arguments = ["check"], # Optional arguments passed directly to the tool
)

command(
    name = "lint-something-else",
    command = ":some_other_linter",
    environment = {"CHECK": "true"}, # Optional environment variables set when invoking the command
    data = ["..."] # Optional runtime data dependencies
)

multirun(
    name = "lint",
    commands = [
        "lint-something",
        "lint-something-else",
    ],
    jobs = 0, # Set to 0 to run in parallel, defaults to sequential
)
```

With this configuration you can `bazel run :lint` and it will run both both
linters in parallel. If you would like to run them serially you can omit the `jobs` attribute.

NOTE: If your commands change files in the workspace you might want to prefer
sequential execution to avoid race conditions when changing the same file from
multiple tools.
""",
    )

multirun = multirun_with_transition("target")
