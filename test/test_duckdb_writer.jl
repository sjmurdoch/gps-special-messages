using Test
using DuckDB
using Dates

# Helper function to create test messages
function create_test_message(;
    time::Int32 = Int32(3600),
    datetime::DateTime = DateTime(2024, 1, 1, 1, 0, 0),
    prn::Int = 5,
    sv_id::Int = 55,
    alert_flag::Bool = false,
    raw_bytes::Vector{UInt8} = UInt8.(collect("TEST MESSAGE 22CHARS!")),
    ascii_message::String = "TEST MESSAGE 22CHARS!",
    frame_inverted::Bool = false,
    parity_ok::Bool = true
)
    return DecodedSpecialMessage(
        time,
        datetime,
        prn,
        sv_id,
        alert_flag,
        raw_bytes,
        ascii_message,
        frame_inverted,
        parity_ok
    )
end

function create_test_metadata(;
    year::Int = 2024,
    day_of_year::Int = 1,
    prn::Int = 5,
    gps_week::Int = 2200,
    source_file::String = "test.arrow"
)
    return FileMetadata(year, day_of_year, prn, gps_week, source_file)
end

@testset "DuckDB Writer" begin
    @testset "Compute Message Hash" begin
        # Test hash computation
        bytes1 = UInt8.(collect("TEST MESSAGE 22CHARS!"))
        hash1 = compute_message_hash(bytes1)

        # Hash should be hex string (64 characters for SHA256)
        @test length(hash1) == 64
        @test all(c -> c in "0123456789abcdef", hash1)

        # Same bytes should produce same hash
        bytes2 = UInt8.(collect("TEST MESSAGE 22CHARS!"))
        hash2 = compute_message_hash(bytes2)
        @test hash1 == hash2

        # Different bytes should produce different hash
        bytes3 = UInt8.(collect("DIFFERENT MSG 22CHAR!"))
        hash3 = compute_message_hash(bytes3)
        @test hash1 != hash3
    end

    @testset "Create Database" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Verify database was created
            @test isfile(db_path)

            # Verify table exists by querying it
            result = DBInterface.execute(db, "SELECT COUNT(*) as count FROM special_messages")
            row = first(result)
            @test row.count == 0  # Should be empty
        finally
            cleanup_test_db(db, db_path)
        end

        # Test replace mode with a fresh path
        db_path2 = tempname() * ".duckdb"
        db2 = create_database(db_path2; replace=true)

        try
            result = DBInterface.execute(db2, "SELECT COUNT(*) as count FROM special_messages")
            row = first(result)
            @test row.count == 0  # Should be empty after replace
        finally
            cleanup_test_db(db2, db_path2)
        end
    end

    @testset "Insert Single Message" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create test message and metadata
            msg = create_test_message()
            meta = create_test_metadata()
            mult = Int32(1)

            # Insert message
            insert_message!(db, msg, meta, mult)

            # Verify message was inserted
            count = get_message_count(db)
            @test count == 1

            # Query the message
            result = DBInterface.execute(db, "SELECT * FROM special_messages")
            row = first(result)

            @test row.prn == 5
            @test row.sv_id == 55
            @test row.ascii_message == "TEST MESSAGE 22CHARS!"
            @test row.alert_flag == false
            @test row.parity_ok == true
            @test row.year == 2024
            @test row.day_of_year == 1
            @test row.source_file == "test.arrow"

            # A parity-failed message is stored with the flag preserved
            msg_bad = create_test_message(datetime=DateTime(2024, 1, 1, 2, 0, 0),
                                          raw_bytes=UInt8.(collect("GARBLED MESSAGE 22CHA")),
                                          ascii_message="GARBLED MESSAGE 22CHA",
                                          parity_ok=false)
            insert_message!(db, msg_bad, meta, mult)
            result = DBInterface.execute(db,
                "SELECT parity_ok FROM special_messages WHERE datetime = '2024-01-01 02:00:00'")
            @test first(result).parity_ok == false
        finally
            cleanup_test_db(db, db_path)
        end
    end

    @testset "Batch Insert Messages" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create multiple test messages
            messages = [
                create_test_message(prn=1, datetime=DateTime(2024, 1, 1, 1, 0, 0)),
                create_test_message(prn=2, datetime=DateTime(2024, 1, 1, 2, 0, 0)),
                create_test_message(prn=3, datetime=DateTime(2024, 1, 1, 3, 0, 0))
            ]

            meta = create_test_metadata()
            multiplicities = Int32[1, 2, 1]

            # Batch insert
            insert_messages!(db, messages, meta, multiplicities)

            # Verify all messages were inserted
            count = get_message_count(db)
            @test count == 3

            # Verify PRNs
            result = DBInterface.execute(db, "SELECT DISTINCT prn FROM special_messages ORDER BY prn")
            prns = [row.prn for row in result]
            @test prns == [1, 2, 3]

            # Verify multiplicities
            result = DBInterface.execute(db, "SELECT prn, multiplicity FROM special_messages ORDER BY prn")
            rows = collect(result)
            @test rows[1].multiplicity == 1
            @test rows[2].multiplicity == 2
            @test rows[3].multiplicity == 1
        finally
            cleanup_test_db(db, db_path)
        end
    end

    @testset "Unique Message Count" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create messages with duplicate content but different timestamps
            bytes = UInt8.(collect("SAME MESSAGE 22CHARS!"))
            messages = [
                create_test_message(
                    datetime=DateTime(2024, 1, 1, i, 0, 0),
                    raw_bytes=bytes,
                    ascii_message="SAME MESSAGE 22CHARS!"
                ) for i in 1:5
            ]

            meta = create_test_metadata()
            multiplicities = fill(Int32(1), 5)

            # Insert messages
            insert_messages!(db, messages, meta, multiplicities)

            # Total count should be 5
            @test get_message_count(db) == 5

            # Unique message count should be 1 (same content)
            @test get_unique_message_count(db) == 1
        finally
            cleanup_test_db(db, db_path)
        end
    end

    @testset "Statistical Fields" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create a message with known properties
            text_msg = UInt8.(collect("HELLO WORLD TEST MSG!"))
            msg = create_test_message(
                raw_bytes=text_msg,
                ascii_message="HELLO WORLD TEST MSG!"
            )

            meta = create_test_metadata()
            insert_message!(db, msg, meta, Int32(1))

            # Query statistical fields
            result = DBInterface.execute(db, """
                SELECT is_likely_text, printable_chars, null_bytes, entropy
                FROM special_messages
            """)
            row = first(result)

            # Verify statistics were computed
            @test row.is_likely_text isa Bool
            @test row.printable_chars isa Integer
            @test row.null_bytes isa Integer
            @test row.entropy isa AbstractFloat

            # Verify they match manual computation
            stats = compute_message_stats(text_msg)
            @test row.is_likely_text == stats.is_likely_text
            @test row.printable_chars == stats.printable_chars
            @test row.null_bytes == stats.null_bytes
            @test row.entropy ≈ stats.entropy
        finally
            cleanup_test_db(db, db_path)
        end
    end

    @testset "Null Byte Handling" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create a message with embedded null bytes (like the error case)
            # This simulates the actual GPS message: "NI4+2 \0EOQPDLSMB7SCVWI"
            null_msg_bytes = UInt8.(collect("NI4+2 \0EOQPDLSMB7SCVWI"))
            null_msg = create_test_message(
                raw_bytes=null_msg_bytes,
                ascii_message="NI4+2 \0EOQPDLSMB7SCVWI"
            )

            meta = create_test_metadata()

            # This should NOT crash - null bytes should be sanitized
            insert_message!(db, null_msg, meta, Int32(1))

            # Verify message was inserted
            count = get_message_count(db)
            @test count == 1

            # Query and verify null byte was replaced with Unicode replacement character
            result = DBInterface.execute(db, "SELECT ascii_message FROM special_messages")
            row = first(result)
            @test row.ascii_message == "NI4+2 �EOQPDLSMB7SCVWI"  # \0 replaced with U+FFFD

            # Verify raw_bytes still contains the original null byte
            result = DBInterface.execute(db, "SELECT raw_bytes FROM special_messages")
            row = first(result)
            retrieved_bytes = collect(row.raw_bytes)
            @test retrieved_bytes == null_msg_bytes  # Original bytes preserved
        finally
            cleanup_test_db(db, db_path)
        end
    end

    @testset "Transaction Rollback on Error" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create messages with one having invalid data to trigger error
            messages = [create_test_message()]
            meta = create_test_metadata()

            # Create mismatched multiplicities (should cause assertion error)
            multiplicities = Int32[]  # Empty - will fail assertion

            # Should raise an error
            @test_throws AssertionError insert_messages!(db, messages, meta, multiplicities)

            # Database should still be in consistent state (0 messages)
            @test get_message_count(db) == 0
        finally
            cleanup_test_db(db, db_path)
        end
    end

    @testset "Duplicate Message Handling" begin
        db_path = tempname() * ".duckdb"
        db = create_database(db_path; replace=true)

        try
            # Create a message
            msg = create_test_message(
                datetime=DateTime(2024, 1, 1, 12, 0, 0),
                prn=5
            )
            meta = create_test_metadata()

            # Insert the message
            insert_message!(db, msg, meta, Int32(1))

            # Verify it was inserted
            @test get_message_count(db) == 1

            # Try to insert the SAME message again (duplicate primary key)
            # This should NOT crash - it should silently skip the duplicate
            insert_message!(db, msg, meta, Int32(1))

            # Count should still be 1 (duplicate was ignored)
            @test get_message_count(db) == 1

            # Now test batch insert with duplicates
            messages = [
                msg,  # Duplicate of what's already in DB
                create_test_message(datetime=DateTime(2024, 1, 1, 13, 0, 0), prn=6),
                msg,  # Duplicate within same batch
                create_test_message(datetime=DateTime(2024, 1, 1, 14, 0, 0), prn=7),
            ]
            multiplicities = fill(Int32(1), 4)

            # Should insert only the 2 new messages, skip 2 duplicates
            insert_messages!(db, messages, meta, multiplicities)

            # Count should be 3 (1 original + 2 new, 2 duplicates skipped)
            @test get_message_count(db) == 3
        finally
            cleanup_test_db(db, db_path)
        end
    end
end
