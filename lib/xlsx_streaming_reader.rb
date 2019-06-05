# The POI streaming XLSX reader is a *very* thin layer over the XML contained in
# the XLSX zip package.  This code is basically doing a SAX parse of the
# workbook.xml and sheet.xml files embedded in the XLSX.
#
# We tried several Ruby gems that handle XLSX files, but all of them had large
# memory footprints (https://github.com/roo-rb/roo/issues/179,
# https://github.com/weshatheleopard/rubyXL/issues/199,
# https://github.com/woahdae/simple_xlsx_reader/issues/25) when parsing large
# spreadsheets.  We would see memory usage of around 30-40x the size of the
# *uncompressed* xlsx file.
#
# This code runs in memory about 3x the size of the uncompressed content, and
# has a narrow enough interface to be easy to replace should a better option
# come along.
#
# The format we're dealing with pretty much looks like this:
#
#   <... outer stuff>
#     <row>
#     </row>
#       <c r="A1" t="n"><v>123</v></c><c r="B1" t="n"><v>456</v></c>
#     <row>
#       <c r="A2" t="n"><v>789</v></c><c r="B2" t="s"><v>hello</v></c>
#     </row>
#     ...
#   </outer stuff>
#
# Rows contain cells, cells contain values.  Types (t) are at the level of cells
# and can be numeric, strings, booleans, nulls, etc..  Each cell also has a
# reference (r) like 'A2'.
#
# Dates are stored as numbers of days since either 1899-12-30 OR 1904-01-01.
# You can tell whether a given cell is a date by looking at its style attribute
# (s).  You can tell which epoch scheme the spreadsheet uses by parsing the
# `date1904` property out of the workbook properties section.
#
# XLSX files are sparse, so empty/null cells are usually not stored.  See "Note
# on sparse cell storage" below for further explanation.

Dir.glob(File.join(File.dirname(__FILE__), 'poi', '**/*.jar')).each do |jar|
  require File.absolute_path(jar)
end

class XLSXStreamingReader

  # The names of the different XML elements we'll be visiting
  ROW_ELEMENT = 'row'
  CELL_ELEMENT = 'c'
  VALUE_ELEMENT = 'v'
  FORMULA_ELEMENT = 'f'

  # The type codes of cells we'll be visiting
  STRING_TYPE = 's'
  NUMERIC_TYPE = 'n'
  BOOLEAN_TYPE = 'b'
  INLINE_STRING_TYPE = 'inlineStr'

  # The attributes of elements we'll need
  ATTRIBUTE_STYLE = 's'
  ATTRIBUTE_REFERENCE = 'r'
  ATTRIBUTE_TYPE = 't'


  def initialize(filename)
    @filename = filename
  end

  def extract_workbook_properties(xssf_reader)
    workbook = xssf_reader.get_workbook_data

    workbook_properties = WorkbookPropertiesExtractor.new
    parse_with_handler(xssf_reader.get_workbook_data, workbook_properties)

    workbook_properties.properties
  end

  def parse_with_handler(input_source, handler)
    parser = org.apache.poi.ooxml.util.SAXHelper.newXMLReader
    parser.set_content_handler(handler)

    parser.parse(org.xml.sax.InputSource.new(input_source))
  end

  def each(sheet_number = 0, &block)
    if block
      each_row(sheet_number, &block)
    else
      self.to_enum(:each_row, sheet_number)
    end
  end

  def each_row(sheet_number = 0, &block)
    pkg = org.apache.poi.openxml4j.opc.OPCPackage.open(@filename)
    xssf_reader = org.apache.poi.xssf.eventusermodel.XSSFReader.new(pkg)
    workbook_properties = extract_workbook_properties(xssf_reader)
    sheet = xssf_reader.get_sheets_data.take(sheet_number + 1).last

    begin
      parse_with_handler(sheet,
                         SheetHandler.new(xssf_reader.get_shared_strings_table,
                                          xssf_reader.get_styles_table,
                                          workbook_properties,
                                          &block))
    ensure
      sheet.close
      pkg.close
    end
  end


  class SheetHandler

    def initialize(string_table, style_table, workbook_properties, &block)
      @current_row = []
      @current_column = nil

      @value = ''
      @value_type_override = nil

      @string_table = string_table
      @style_table = style_table
      @workbook_properties = workbook_properties

      @row_handler = block
    end

    # Turn A into 1; Z into 26; AA into 27, etc.
    def col_reference_to_index(s)
      raise ArgumentError.new(s) unless s =~ /\A[A-Z]+\z/
      val = 0
      s.split("").each do |ch|
        val *= 26
        val += (ch.ord - 'A'.ord) + 1
      end

      val
    end

    def start_element(uri, local_name, name, attributes)
      if local_name == ROW_ELEMENT
        # New row
        @current_row = []
        @last_column = 'A'
      elsif local_name == CELL_ELEMENT
        @value = ''

        # Note on sparse cell storage
        #
        # If we've skipped over columns since the last cell, we need to insert padding.
        #
        # This is because the spreadsheet doesn't contain entries for cells with
        # null values, so a spreadsheet with a value in column 1 and a value in
        # column 10 will contain only two cell entries, even though there are
        # conceptually 10 cells.  Those 8 null cells exist in our hearts and
        # minds, but not in the xlsx XML.
        current_column = attributes.getValue(ATTRIBUTE_REFERENCE).gsub(/[0-9]+/, '')

        # Calculate the number of columns between column refs like AA and AC
        gap = col_reference_to_index(current_column) - col_reference_to_index(@last_column)
        if gap > 1
          # Pad empty columns with nils
          @current_row.concat([nil] * (gap - 1))
        end

        @last_column = current_column

        # New cell
        case attributes.getValue(ATTRIBUTE_TYPE)
        when STRING_TYPE
          @value_type = :string
        when NUMERIC_TYPE, nil
          # A number can represent a date depending on the style of the cell.
          style_number = attributes.getValue(ATTRIBUTE_STYLE)
          style = !style_number.to_s.empty? && @style_table.getStyleAt(Integer(style_number))
          is_date = style && org.apache.poi.ss.usermodel.DateUtil.isADateFormat(style.get_data_format, style.get_data_format_string)

          if is_date
            @value_type = :date
          else
            @value_type = :number
          end
        when BOOLEAN_TYPE
          @value_type = :boolean
        when INLINE_STRING_TYPE
          @value_type = :inline_string
        else
          @value_type = :unknown
        end
      elsif local_name == VALUE_ELEMENT || local_name == FORMULA_ELEMENT
        # New value within cell
        @reading_value = true
        @value = ''
      end
    end

    def end_element(uri, local_name, name)
      if local_name == ROW_ELEMENT
        # Finished our row.  Yield it.
        @row_handler.call(@current_row)
      elsif local_name == FORMULA_ELEMENT
        # @value contains the content of the formula.
        if ['TRUE()', 'FALSE()'].include?(@value)
          # Override the next value we read to be marked as a boolean.  Open
          # Office seems to (sometimes) express booleans as a formula rather
          # than as a cell type.
          @value_type_override = :boolean
        end
        @value = ''
        @reading_value = false
      elsif local_name == VALUE_ELEMENT
        @reading_value = false
      elsif local_name == CELL_ELEMENT
        # Finished our cell.  Process its value.
        parsed_value = case @value_type
                       when :string
                         @string_table.get_item_at(Integer(@value)).get_string
                       when :number
                         if @value == ''
                           nil
                         elsif @value_type_override == :boolean
                           Integer(@value) == 1
                         else
                           begin
                             Integer(@value)
                           rescue ArgumentError
                             Float(@value)
                           end
                         end
                       when :date
                         if @value == ''
                           nil
                         else
                           java_date = org.apache.poi.ss.usermodel.DateUtil.get_java_date(Float(@value),
                                                                                          @workbook_properties['date1904'] == 'true')
                           Time.at(java_date.getTime / 1000)
                         end
                       when :boolean
                         @value != '0'
                       when :inline_string
                         @value.to_s
                       else
                         @value.to_s
                       end

        @value_type_override = nil
        @current_row << parsed_value
      end
    end

    def characters(chars, start, length)
      if @reading_value
        @value += java.lang.String.new(chars, start, length)
      end
    end

    def method_missing(*)
      # Don't care
    end
  end


  class WorkbookPropertiesExtractor
    def initialize
      @properties = {}
    end

    def method_missing(*)
      # Ignored
    end

    def start_element(uri, local_name, name, attributes)
      if local_name == 'workbookPr'
        attributes.getLength.times do |i|
          @properties[attributes.getName(i)] = attributes.getValue(i)
        end
      end
    end

    def properties
      @properties
    end
  end
end