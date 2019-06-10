require 'time'
require_relative '../lib/xlsx_streaming_reader'

class TestXLSXStreamingReader

  def test_big_sheet
    ['ooffice_big_sheet.xlsx', 'excel_big_sheet.xlsx'].each do |file|
      count = 0
      XLSXStreamingReader.new(fixture_file(file)).each do |row|
        count += 1
      end

      assert_equal(file, 10001, count)
    end
  end

  EXOTIC_CONTENT = [
    ["stringcol", "numcol", "formulacol", "nullcol", "booleancol", "datecol"],
    ["hello", 123, 6, nil, true, Time.parse('2019-03-10 00:00:00')],
    ["world", 123.45, 6, nil, false, Time.parse('2000-01-01 00:00:00')],
    [nil, nil, nil, nil, nil, nil],
    ["\xE5\xBC\x82\xE5\x9B\xBD\xE6\x83\x85\xE8\xB0\x83", -100, 100, nil, false, Time.parse('2050-06-30 00:00:00')],
    [nil, -100, 100, nil, false, Time.parse('2050-06-30 00:00:00')]
  ]

  def test_exotic_sheet
    ['ooffice_exotic_sheet.xlsx', 'excel_exotic_sheet.xlsx', 'mac_excel_exotic_sheet.xlsx'].each do |file|
      XLSXStreamingReader.new(fixture_file(file)).each.each_with_index do |row, idx|
        assert_equal(file, EXOTIC_CONTENT[idx], row)
      end
    end
  end

  def fixture_file(name)
    File.join(File.dirname(__FILE__), 'fixtures', name)
  end

  def assert_equal(file, expected, actual)
    if expected == actual
      puts "PASS: #{caller[0]}"
    else
      puts "FAIL #{file}: Expected #{expected} but got #{actual}" unless expected == actual
    end
  end

  def call
    test_exotic_sheet
    test_big_sheet
  end

end


TestXLSXStreamingReader.new.call
