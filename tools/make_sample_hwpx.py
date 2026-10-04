"""Builds a small HWPX test document (paragraph styles, table with merged cells, image).

The structure mirrors what Hangul writes; it is intentionally minimal so the
test fixture stays readable. Run: python3 tools/make_sample_hwpx.py <out.hwpx>
"""
import base64
import sys
import zipfile

NS = ('xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" '
      'xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" '
      'xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" '
      'xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"')

# 1x1 red PNG
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")

HEADER = f'''<?xml version="1.0" encoding="UTF-8"?>
<hh:head {NS} version="1.4" secCnt="1"><hh:refList>
<hh:fontfaces itemCnt="2">
 <hh:fontface lang="HANGUL" fontCnt="2"><hh:font id="0" face="함초롬돋움" type="TTF"/><hh:font id="1" face="함초롬바탕" type="TTF"/></hh:fontface>
 <hh:fontface lang="LATIN" fontCnt="1"><hh:font id="0" face="Arial" type="TTF"/></hh:fontface>
</hh:fontfaces>
<hh:borderFills itemCnt="2">
 <hh:borderFill id="1"><hh:leftBorder type="NONE" width="0.1 mm" color="#000000"/><hh:rightBorder type="NONE" width="0.1 mm" color="#000000"/><hh:topBorder type="NONE" width="0.1 mm" color="#000000"/><hh:bottomBorder type="NONE" width="0.1 mm" color="#000000"/></hh:borderFill>
 <hh:borderFill id="2"><hh:leftBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:rightBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:topBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:bottomBorder type="DOUBLE_SLIM" width="0.5 mm" color="#0000FF"/><hc:fillBrush><hc:winBrush faceColor="#FFF2CC" hatchColor="#000000" alpha="0"/></hc:fillBrush></hh:borderFill>
</hh:borderFills>
<hh:charProperties itemCnt="3">
 <hh:charPr id="0" height="1000" textColor="#000000" shadeColor="none" borderFillIDRef="1"><hh:fontRef hangul="1" latin="0"/><hh:ratio hangul="100"/><hh:spacing hangul="0"/><hh:relSz hangul="100"/></hh:charPr>
 <hh:charPr id="1" height="1600" textColor="#1F4E79" shadeColor="none" borderFillIDRef="1"><hh:fontRef hangul="0" latin="0"/><hh:ratio hangul="100"/><hh:spacing hangul="-5"/><hh:relSz hangul="100"/><hh:bold/></hh:charPr>
 <hh:charPr id="2" height="1000" textColor="#C00000" shadeColor="#FFFF00" borderFillIDRef="1"><hh:fontRef hangul="0" latin="0"/><hh:ratio hangul="100"/><hh:spacing hangul="0"/><hh:relSz hangul="100"/><hh:italic/><hh:underline type="BOTTOM" shape="SOLID" color="#000000"/></hh:charPr>
</hh:charProperties>
<hh:paraProperties itemCnt="2">
 <hh:paraPr id="0"><hh:align horizontal="JUSTIFY" vertical="BASELINE"/><hp:switch><hp:case hp:required-namespace="http://www.hancom.co.kr/hwpml/2016/HwpUnitChar"><hh:margin><hc:intent value="-1000" unit="HWPUNIT"/><hc:left value="2000" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="600" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/></hp:case><hp:default><hh:margin><hc:intent value="-2000" unit="HWPUNIT"/><hc:left value="4000" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="1200" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/></hp:default></hp:switch></hh:paraPr>
 <hh:paraPr id="1"><hh:align horizontal="CENTER" vertical="BASELINE"/><hh:margin><hc:intent value="0" unit="HWPUNIT"/><hc:left value="0" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="0" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="130" unit="HWPUNIT"/></hh:paraPr>
</hh:paraProperties>
</hh:refList></hh:head>'''


def cell(col, row, text, colspan=1, rowspan=1, width=14000):
    return (f'<hp:tc borderFillIDRef="2"><hp:subList vertAlign="CENTER">'
            f'<hp:p paraPrIDRef="1"><hp:run charPrIDRef="0"><hp:t>{text}</hp:t></hp:run></hp:p></hp:subList>'
            f'<hp:cellAddr colAddr="{col}" rowAddr="{row}"/><hp:cellSpan colSpan="{colspan}" rowSpan="{rowspan}"/>'
            f'<hp:cellSz width="{width}" height="1500"/><hp:cellMargin left="510" right="510" top="141" bottom="141"/></hp:tc>')


SECTION = f'''<?xml version="1.0" encoding="UTF-8"?>
<hs:sec {NS}>
<hp:p paraPrIDRef="1"><hp:run charPrIDRef="1"><hp:secPr><hp:pagePr landscape="WIDELY" width="59528" height="84188"><hp:margin header="4252" footer="4252" gutter="0" left="8504" right="8504" top="5668" bottom="4252"/></hp:pagePr></hp:secPr><hp:t>Claude 보고서 제목</hp:t></hp:run></hp:p>
<hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>첫 문단입니다.<hp:tab/>탭 뒤 &amp; 특수문자 &lt;태그&gt;</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>강조된 글자<hp:lineBreak/>줄바꿈 후</hp:t></hp:run></hp:p>
<hp:p paraPrIDRef="1"><hp:run charPrIDRef="0"><hp:tbl rowCnt="3" colCnt="3" borderFillIDRef="1"><hp:sz width="42000" height="4500"/><hp:inMargin left="510" right="510" top="141" bottom="141"/>
<hp:tr>{cell(0,0,"항목",width=14000)}{cell(1,0,"내용",colspan=2,width=28000)}</hp:tr>
<hp:tr>{cell(0,1,"병합",rowspan=2)}{cell(1,1,"가")}{cell(2,1,"나")}</hp:tr>
<hp:tr>{cell(1,2,"다")}{cell(2,2,"라")}</hp:tr>
</hp:tbl><hp:t/></hp:run></hp:p>
<hp:p paraPrIDRef="1"><hp:run charPrIDRef="0"><hp:pic><hp:sz width="7200" height="7200"/><hc:img binaryItemIDRef="image1"/></hp:pic></hp:run></hp:p>
<hp:p paraPrIDRef="0" pageBreak="1"><hp:run charPrIDRef="0"><hp:t>두 번째 쪽</hp:t></hp:run></hp:p>
<hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"/></hp:p>
</hs:sec>'''

CONTENT = '''<?xml version="1.0" encoding="UTF-8"?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf/"><opf:metadata><opf:title>샘플 문서</opf:title></opf:metadata>
<opf:manifest>
<opf:item id="header" href="Contents/header.xml" media-type="application/xml"/>
<opf:item id="image1" href="BinData/image1.png" media-type="image/png" isEmbeded="1"/>
<opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/>
</opf:manifest><opf:spine><opf:itemref idref="header"/><opf:itemref idref="section0"/></opf:spine></opf:package>'''

CONTAINER = '''<?xml version="1.0" encoding="UTF-8"?>
<ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container"><ocf:rootfiles>
<ocf:rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/>
</ocf:rootfiles></ocf:container>'''


def main(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/hwp+zip")
        z.writestr("META-INF/container.xml", CONTAINER, zipfile.ZIP_DEFLATED)
        z.writestr("Contents/content.hpf", CONTENT, zipfile.ZIP_DEFLATED)
        z.writestr("Contents/header.xml", HEADER, zipfile.ZIP_DEFLATED)
        z.writestr("Contents/section0.xml", SECTION, zipfile.ZIP_DEFLATED)
        z.writestr("BinData/image1.png", PNG, zipfile.ZIP_STORED)


if __name__ == "__main__":
    main(sys.argv[1])
