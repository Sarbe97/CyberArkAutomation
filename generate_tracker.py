import xlsxwriter
from datetime import datetime

def generate_tracker():
    filename = 'Construction_Tracker_Final.xlsx'
    workbook = xlsxwriter.Workbook(filename)
    
    # --- STYLES ---
    header_style = {'bold': True, 'bg_color': '#1A237E', 'font_color': 'white', 'border': 1, 'align': 'center'}
    header_format = workbook.add_format(header_style)
    sub_header_format = workbook.add_format({'bold': True, 'bg_color': '#E8EAF6', 'border': 1, 'align': 'center'})
    currency_format = workbook.add_format({'num_format': '₹#,##0.00'})
    date_format = workbook.add_format({'num_format': 'dd-mm-yyyy'})
    
    dashboard_title_format = workbook.add_format({
        'bold': True, 'bg_color': '#303F9F', 'font_color': 'white', 'font_size': 14, 'align': 'center'
    })

    # --- SHEET 1: Master_Data ---
    data_sheet = workbook.add_worksheet('Master_Data')
    data_headers = ['Expense Categories', 'Vendors / Entities', 'Payment Modes', 'Projects / Components']
    data_sheet.write_row(0, 0, data_headers, header_format)
    
    cats = ['Sand', 'Cement', 'Steel', 'Bricks', 'Aggregate', 'Labour', 'Food / Fuel', 'Misc', 'Hardware']
    vnrs = ['Other', 'Sand Vendor A', 'Labour Contractor B', 'Cement Supplier C', 'Electrician', 'Plumber']
    mods = ['UPI', 'Cash', 'Bank Transfer']
    projs = ['Main House', 'Outhouse', 'Pump House', 'Compound Wall']
    
    for i, v in enumerate(cats): data_sheet.write(i+1, 0, v)
    for i, v in enumerate(vnrs): data_sheet.write(i+1, 1, v)
    for i, v in enumerate(mods): data_sheet.write(i+1, 2, v)
    for i, v in enumerate(projs): data_sheet.write(i+1, 3, v)
    data_sheet.set_column('A:E', 20)

    # --- SHEET 2: Master_Log (WITH HELPER COLUMN) ---
    log_sheet = workbook.add_worksheet('Master_Log')
    # Cols A-H: Data | Col I: Search Index (Hidden)
    log_headers = ['Date', 'Category', 'Project / Component', 'Vendor / Contractor', 'Bill Amount', 'Paid Amount', 'Payment Mode', 'Remarks', 'Search Index']
    log_sheet.write_row(0, 0, log_headers, header_format)
    log_sheet.freeze_panes(1, 0)
    log_sheet.set_column('A:H', 20)
    log_sheet.set_column('I:I', 5, None, {'hidden': True}) # Hide the helper column
    
    log_sheet.data_validation('B2:B2000', {'validate': 'list', 'source': '=Master_Data!$A$2:$A$100'})
    log_sheet.data_validation('D2:D2000', {'validate': 'list', 'source': '=Master_Data!$B$2:$B$100'})
    
    # Write the helper index formula for 1000 rows
    # Logic: If Vendor equals selection in Statement B3, give it a unique number (1, 2, 3...)
    for r in range(2, 1001):
        index_formula = f"=IF(D{r}=Vendor_Statement!$B$3, COUNTIF($D$2:D{r}, Vendor_Statement!$B$3), \"\")"
        log_sheet.write_formula(r-1, 8, index_formula)

    # --- SHEET 3: Vendor_Statement (NO-FAIL INDEX/MATCH VERSION) ---
    st_sheet = workbook.add_worksheet('Vendor_Statement')
    st_sheet.set_column('A:H', 20)
    st_sheet.merge_range('A1:I1', 'VENDOR ACCOUNT STATEMENT (STABLE VERSION)', dashboard_title_format)
    
    st_sheet.write('A3', 'Select Vendor:', workbook.add_format({'bold': True}))
    st_sheet.data_validation('B3', {'validate': 'list', 'source': '=Master_Data!$B$2:$B$100'})
    
    st_sheet.write('D3', 'Total Balance:', workbook.add_format({'bold': True}))
    st_sheet.write_formula('E3', "=SUMIF('Master_Log'!D:D, B3, 'Master_Log'!E:E) - SUMIF('Master_Log'!D:D, B3, 'Master_Log'!F:F)", currency_format)

    st_headers = ['Date', 'Category', 'Project', 'Vendor', 'Bill', 'Paid', 'Mode', 'Remarks']
    st_sheet.write_row(5, 0, st_headers, header_format)

    # The No-Fail Formulas (Index Match based on the hidden Index column)
    # This works on EVERY platform (Excel, Google Sheets, Mobile)
    log_cols = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']
    for row_num in range(1, 101): # Fill 100 rows
        r_write = row_num + 6 # Starting from Row 7
        for col_idx, col_letter in enumerate(log_cols):
            # Formula: Match row #N in the Master_Log index column, then pull the value
            formula = (
                f"=IFERROR(INDEX('Master_Log'!${col_letter}:${col_letter}, "
                f"MATCH({row_num}, 'Master_Log'!$I:$I, 0)), \"\")"
            )
            if col_letter == 'A':
                st_sheet.write_formula(r_write-1, col_idx, formula, date_format)
            elif col_letter in ['E', 'F']:
                st_sheet.write_formula(r_write-1, col_idx, formula, currency_format)
            else:
                st_sheet.write_formula(r_write-1, col_idx, formula)

    # --- SHEET 4: Summary_Dashboard ---
    dash_sheet = workbook.add_worksheet('Summary_Dashboard')
    dash_sheet.set_column('A:L', 22)
    dash_sheet.merge_range('A1:L1', 'CONSTRUCTION COST DASHBOARD', dashboard_title_format)
    dash_sheet.write('A3', 'Project Cost (Billed)'); dash_sheet.write_formula('B3', "=SUM('Master_Log'!E:E)", currency_format)
    dash_sheet.write('A4', 'Cash Paid (Payout)'); dash_sheet.write_formula('B4', "=SUM('Master_Log'!F:F)", currency_format)

    # Vendor Summary Table
    dash_sheet.write('D8', 'Vendor Summary', header_format)
    dash_sheet.write_row(8, 3, ['Name', 'Billed', 'Paid', 'Balance'], sub_header_format)
    for i in range(25):
        row_idx = 10 + i
        dash_sheet.write_formula(row_idx-1, 3, f"=IF(Master_Data!B{i+2}=\"\", \"\", Master_Data!B{i+2})")
        dash_sheet.write_formula(row_idx-1, 4, f"=IF(D{row_idx}=\"\", \"\", SUMIF('Master_Log'!D:D, D{row_idx}, 'Master_Log'!E:E))", currency_format)
        dash_sheet.write_formula(row_idx-1, 5, f"=IF(D{row_idx}=\"\", \"\", SUMIF('Master_Log'!D:D, D{row_idx}, 'Master_Log'!F:F))", currency_format)
        dash_sheet.write_formula(row_idx-1, 6, f"=IF(D{row_idx}=\"\", \"\", E{row_idx} - F{row_idx})", currency_format)

    workbook.close()
    print("Successfully generated No-Fail Universal Tracker (V13)")

if __name__ == '__main__':
    generate_tracker()
