load("@bazel_skylib//:bzl_library.bzl", "bzl_library")
load("//:defs.bzl", "command")
load("//internal:runfiles_enabled.bzl", "runfiles_enabled")

runfiles_enabled(
    name = "runfiles_enabled",
    enable_runfiles = select({
        "@aspect_bazel_lib//lib:enable_runfiles": True,
        "//conditions:default": False,
    }),
    visibility = ["//visibility:public"],
)

exports_files(
    glob(["*.bzl"]),
    visibility = ["//doc:__pkg__"],
)

command(
    name = "root_command",
    command = "//tests:echo_hello",
    visibility = ["//tests:__pkg__"],
)

bzl_library(
    name = "defs",
    srcs = ["defs.bzl"],
    visibility = ["//visibility:public"],
    deps = [
        ":command",
        ":multirun",
    ],
)

bzl_library(
    name = "multirun",
    srcs = ["multirun.bzl"],
    visibility = ["//visibility:public"],
    deps = [
        "//internal:constants",
        "//internal:runfiles_enabled",
        "@bazel_skylib//lib:shell",
    ],
)

bzl_library(
    name = "command",
    srcs = ["command.bzl"],
    visibility = ["//visibility:public"],
    deps = [
        "//internal:constants",
        "@bazel_skylib//lib:shell",
    ],
)
