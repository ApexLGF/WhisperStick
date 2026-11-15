// QuickVibeCLIScenarioTests.swift
// [QuickVibe patch] 我们自己的 CLI 口述场景验收集(vendor 时新增,非上游文件)。
// 覆盖两类:① 必须正确转换的高频 CLI 表达;② 绝不能误转的守卫反例。
// 其中"纯读数串 ≥3 位全转"依赖 Cardinal.swift 的 QuickVibe patch。

import XCTest
@testable import ChineseITN

final class QuickVibeCLIScenarioTests: XCTestCase {

    private func n(_ s: String) -> String {
        ChineseITN.normalize(s)
    }

    // MARK: ① 必须正确转换

    func testBareDigitRunDate() {
        // 触发本次接入的原始 bug:8 位日期读数串
        XCTAssertEqual(n("二零二六零七零三"), "20260703")
        XCTAssertEqual(n("版本号二零二六零七零三"), "版本号20260703")
    }

    func testBareDigitRunOtherLengths() {
        XCTAssertEqual(n("四零四"), "404")                    // 3 位(上游本就支持)
        XCTAssertEqual(n("二零二六"), "2026")                  // 4 位
        XCTAssertEqual(n("一二三四五六"), "123456")            // 6 位(patch 放开)
        XCTAssertEqual(n("幺三八幺幺幺零零零零零"), "13811100000") // 11 位电话
    }

    func testPortsAndVersions() {
        XCTAssertEqual(n("三千端口"), "3000端口")
        XCTAssertEqual(n("端口八零八零"), "端口8080")
        XCTAssertEqual(n("版本一点二"), "版本1.2")
        XCTAssertEqual(n("回滚到版本二点五点零"), "回滚到版本2.5.0")
    }

    func testCommonCLIExpressions() {
        XCTAssertEqual(n("把超时改成三十秒"), "把超时改成30秒")
        XCTAssertEqual(n("百分之八十"), "80%")
        XCTAssertEqual(n("三分之二"), "2/3")
        XCTAssertEqual(n("十五分钟后跑测试"), "15分钟后跑测试")
        XCTAssertEqual(n("内存四点零八个G"), "内存4.08个G")
    }

    func testDateForms() {
        XCTAssertEqual(n("二零二六年七月三号"), "2026/07/03")
        XCTAssertEqual(n("二零二六年七月三日"), "2026/07/03")
    }

    // MARK: ② 误转守卫(原样保留)

    func testIdiomAndProperNounGuards() {
        XCTAssertEqual(n("二胡拉得好"), "二胡拉得好")
        XCTAssertEqual(n("三国演义"), "三国演义")
        XCTAssertEqual(n("四川人吃辣"), "四川人吃辣")
        XCTAssertEqual(n("百闻不如一见"), "百闻不如一见")
    }

    func testVagueQuantifierGuards() {
        // 2 位纯读数串仍不转(模糊量词,patch 保留上游语义)
        XCTAssertEqual(n("来七八个人"), "来七八个人")
        XCTAssertEqual(n("三五百块钱"), "三五百块钱")
        XCTAssertEqual(n("十五六岁"), "十五六岁")
    }
}
