import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import '../models/case_model.dart';

/// Generates legal documents as PDFs — works 100% OFFLINE
class PdfService {
  // ══════════ EXEMPTION APPLICATION ══════════

  /// Generate Exemption Application (Sec 205/317 CrPC)
  static Future<Uint8List> generateExemptionApplication({
    required CaseModel caseData,
    required String reason,
    required String lawyerName,
  }) async {
    final pdf = pw.Document();
    final today = DateFormat('dd/MM/yyyy').format(DateTime.now());

    final fontRegular = await PdfGoogleFonts.interRegular();
    final fontBold = await PdfGoogleFonts.interBold();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(50),
        theme: pw.ThemeData.withFont(
          base: fontRegular,
          bold: fontBold,
        ),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Center(
              child: pw.Text(
                'IN THE COURT OF ${caseData.courtRoom.toUpperCase()}',
                style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
                textAlign: pw.TextAlign.center,
              ),
            ),
            pw.Center(
              child: pw.Text(
                'AT ${caseData.courtComplex.toUpperCase()}',
                style: const pw.TextStyle(fontSize: 12),
              ),
            ),
            pw.SizedBox(height: 24),
            pw.Center(
              child: pw.Text(
                '${caseData.caseType} No. ${caseData.regNo ?? "___"}/${caseData.year}',
                style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 16),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                    child: pw.Text(caseData.petitioner,
                        style: const pw.TextStyle(fontSize: 12))),
                pw.Text('...Complainant / Petitioner',
                    style: const pw.TextStyle(fontSize: 10)),
              ],
            ),
            pw.Center(
              child: pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 8),
                child: pw.Text('VERSUS',
                    style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              ),
            ),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                    child: pw.Text(caseData.respondent,
                        style: const pw.TextStyle(fontSize: 12))),
                pw.Text('...Accused / Respondent',
                    style: const pw.TextStyle(fontSize: 10)),
              ],
            ),
            pw.SizedBox(height: 24),
            pw.Center(
              child: pw.Text(
                'APPLICATION FOR EXEMPTION FROM PERSONAL APPEARANCE',
                style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                    decoration: pw.TextDecoration.underline),
              ),
            ),
            pw.Center(
              child: pw.Text('(Under Section 205/317 of Cr.P.C.)',
                  style: const pw.TextStyle(fontSize: 11)),
            ),
            pw.SizedBox(height: 20),
            pw.Text('Most Respectfully Showeth:',
                style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 12),
            _para('1. That the above-named matter is pending before this Hon\'ble '
                'Court and is listed for hearing on the date fixed.'),
            pw.SizedBox(height: 8),
            _para('2. That the Accused/Respondent is unable to appear before this '
                'Hon\'ble Court on the date fixed due to the following reason:'),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey)),
              child: pw.Text('REASON: ${reason.toUpperCase()}',
                  style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 8),
            _para('3. That the Accused/Respondent undertakes to appear on the '
                'next date of hearing without fail.'),
            pw.SizedBox(height: 8),
            _para('4. It is therefore most respectfully prayed that this Hon\'ble '
                'Court may be pleased to exempt the Accused/Respondent from personal '
                'appearance for today\'s date and adjourn the matter to the next date.'),
            pw.SizedBox(height: 30),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Date: $today', style: const pw.TextStyle(fontSize: 12)),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('_________________________'),
                    pw.SizedBox(height: 4),
                    pw.Text(lawyerName,
                        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Counsel for Accused/Respondent',
                        style: const pw.TextStyle(fontSize: 10)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Text('Place: ${caseData.district}',
                style: const pw.TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );

    return pdf.save();
  }

  // ══════════ ADJOURNMENT APPLICATION ══════════

  static Future<Uint8List> generateAdjournmentApplication({
    required CaseModel caseData,
    required String reason,
    required String lawyerName,
  }) async {
    final pdf = pw.Document();
    final today = DateFormat('dd/MM/yyyy').format(DateTime.now());

    final fontRegular = await PdfGoogleFonts.interRegular();
    final fontBold = await PdfGoogleFonts.interBold();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(50),
        theme: pw.ThemeData.withFont(
          base: fontRegular,
          bold: fontBold,
        ),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Center(
                child: pw.Text(
                    'IN THE COURT OF ${caseData.courtRoom.toUpperCase()}',
                    style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold))),
            pw.Center(
                child: pw.Text('AT ${caseData.courtComplex.toUpperCase()}',
                    style: const pw.TextStyle(fontSize: 12))),
            pw.SizedBox(height: 20),
            pw.Center(
                child: pw.Text(
                    '${caseData.caseType} No. ${caseData.regNo ?? "___"}/${caseData.year}',
                    style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold))),
            pw.SizedBox(height: 12),
            pw.Text('${caseData.petitioner} ...Petitioner/Complainant'),
            pw.Center(
                child: pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 6),
                    child: pw.Text('VERSUS',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold)))),
            pw.Text('${caseData.respondent} ...Respondent/Accused'),
            pw.SizedBox(height: 20),
            pw.Center(
                child: pw.Text('APPLICATION FOR ADJOURNMENT',
                    style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                        decoration: pw.TextDecoration.underline))),
            pw.SizedBox(height: 16),
            pw.Text('Most Respectfully Showeth:',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 10),
            _para('1. That the above case is listed for hearing today before '
                'this Hon\'ble Court.'),
            pw.SizedBox(height: 6),
            _para('2. That the applicant seeks adjournment on the ground of: $reason'),
            pw.SizedBox(height: 6),
            _para('3. The applicant undertakes not to seek adjournment on the next date.'),
            pw.SizedBox(height: 6),
            _para('4. It is prayed that this Hon\'ble Court may be pleased to adjourn '
                'the matter to a convenient date.'),
            pw.SizedBox(height: 30),
            pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Date: $today'),
                  pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('_________________________'),
                        pw.SizedBox(height: 4),
                        pw.Text(lawyerName,
                            style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                        pw.Text('Advocate', style: const pw.TextStyle(fontSize: 10)),
                      ]),
                ]),
            pw.SizedBox(height: 8),
            pw.Text('Place: ${caseData.district}'),
          ],
        ),
      ),
    );
    return pdf.save();
  }

  // ══════════ OUTPUT ══════════

  /// Open print/preview dialog
  static Future<void> previewPdf(Uint8List bytes, String title) async {
    await Printing.layoutPdf(onLayout: (_) => bytes, name: title);
  }

  /// Share PDF via system share sheet
  static Future<void> sharePdf(Uint8List bytes, String title) async {
    await Printing.sharePdf(bytes: bytes, filename: '$title.pdf');
  }

  // ══════════ HELPER ══════════
  static pw.Widget _para(String text) {
    return pw.Text(text, style: const pw.TextStyle(fontSize: 12, lineSpacing: 5));
  }
}