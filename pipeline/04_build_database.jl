#!/usr/bin/env julia
#
# Build the GPS special-messages DuckDB from a directory of Arrow files.
#
# Usage:
#   julia --project [-t auto] pipeline/04_build_database.jl [input_dir] [database_file]
#
# Arguments:
#   input_dir       Directory containing Arrow files (default: data/arrow)
#   database_file   Output DuckDB path             (default: data/messages.duckdb)
#
# Examples:
#   julia --project -t auto pipeline/04_build_database.jl
#   julia --project -t auto pipeline/04_build_database.jl data/arrow_test data/test.duckdb

include(joinpath(@__DIR__, "..", "src", "GPSSpecialMessages.jl"))
using .GPSSpecialMessages

function print_usage()
    println(stderr, "Usage:")
    println(stderr, "  julia --project [-t auto] pipeline/04_build_database.jl [input_dir] [database_file]")
    println(stderr, "")
    println(stderr, "Arguments:")
    println(stderr, "  input_dir       Directory containing Arrow files (default: data/arrow)")
    println(stderr, "  database_file   Output DuckDB path             (default: data/messages.duckdb)")
end

function main()
    if "--help" in ARGS || "-h" in ARGS
        print_usage()
        exit(0)
    end

    input_dir = get(ARGS, 1, "data/arrow")
    db_file   = get(ARGS, 2, "data/messages.duckdb")

    if length(ARGS) > 2
        println(stderr, "Error: Too many arguments")
        print_usage()
        exit(1)
    end

    if !isdir(input_dir)
        println(stderr, "Error: Directory '$input_dir' does not exist")
        exit(1)
    end

    println(stderr, "GPS Special Message Database Builder")
    println(stderr, "====================================")
    println(stderr, "Input directory: $input_dir")
    println(stderr, "Database file:   $db_file")
    println(stderr, "Threads:         $(Threads.nthreads())")
    println(stderr, "")

    start_time = time()
    count = process_directory_to_db_parallel(input_dir, db_file; verbose=true)
    elapsed = time() - start_time

    println(stderr, "")
    println(stderr, "Database created: $db_file")
    println(stderr, "Total messages:   $count")
    println(stderr, "Completed in $(round(elapsed, digits=2)) seconds")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
