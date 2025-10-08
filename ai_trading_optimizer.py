#!/usr/bin/env python3
"""
AI Trading Optimizer for XAUUSD Scalping EA
Sử dụng OpenAI API để đánh giá hiệu quả giao dịch và đưa ra khuyến nghị điều chỉnh.
"""

import json
import os
from datetime import datetime
from typing import Any, Dict, Optional

from openai import OpenAI


class AITradingOptimizer:
    """Công cụ tối ưu hóa giao dịch sử dụng AI cho EA XAUUSD M1."""

    def __init__(self, api_key: str):
        self.client = OpenAI(api_key=api_key)
        self.config_file = "AI_Config.json"
        self.performance_file = "Performance_Data.json"
        self.ai_analysis_file = "AI_Analysis.json"
        self.recommendations_file = "AI_Recommendations.json"

    # ------------------------------------------------------------------
    # JSON HELPERS
    # ------------------------------------------------------------------
    def load_json(self, filename: str) -> Optional[Dict[str, Any]]:
        """Load JSON file."""
        try:
            with open(filename, "r", encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            print(f"❌ File not found: {filename}")
            return None
        except json.JSONDecodeError:
            print(f"❌ Invalid JSON in: {filename}")
            return None

    def save_json(self, filename: str, data: Dict[str, Any]) -> None:
        """Save JSON file."""
        with open(filename, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

    # ------------------------------------------------------------------
    # PERFORMANCE ANALYSIS
    # ------------------------------------------------------------------
    def analyze_performance(self) -> Optional[Dict[str, Any]]:
        """Phân tích dữ liệu hiệu suất giao dịch."""
        perf_data = self.load_json(self.performance_file)

        if not perf_data:
            return None

        daily_perf = perf_data.get("daily_performance", {})
        current_settings = perf_data.get("current_settings", {})

        analysis = {
            "timestamp": datetime.now().isoformat(),
            "overall_health": self.calculate_health_score(daily_perf),
            "risk_level": self.assess_risk_level(daily_perf),
            "profit_potential": self.assess_profit_potential(daily_perf),
            "current_settings": current_settings,
            "recommendations": [],
        }

        self.save_json(self.ai_analysis_file, analysis)
        return analysis

    def calculate_health_score(self, perf: Dict[str, Any]) -> int:
        """Tính điểm sức khỏe (0-100)."""
        score = 50

        win_rate = float(perf.get("win_rate", 0))
        if win_rate >= 60:
            score += 30
        elif win_rate >= 55:
            score += 25
        elif win_rate >= 50:
            score += 20
        elif win_rate >= 45:
            score += 10

        profit_factor = float(perf.get("profit_factor", 0))
        if profit_factor >= 2.0:
            score += 30
        elif profit_factor >= 1.5:
            score += 20
        elif profit_factor >= 1.2:
            score += 10

        consec_losses = int(perf.get("consecutive_losses", 0))
        score -= consec_losses * 5

        daily_profit = float(perf.get("daily_profit", 0))
        if daily_profit > 0:
            score += min(20, daily_profit / 10)
        else:
            score += max(-20, daily_profit / 5)

        return max(0, min(100, int(score)))

    def assess_risk_level(self, perf: Dict[str, Any]) -> str:
        """Đánh giá mức độ rủi ro."""
        consec_losses = int(perf.get("consecutive_losses", 0))
        win_rate = float(perf.get("win_rate", 0))
        profit_factor = float(perf.get("profit_factor", 0))

        if consec_losses >= 4 or win_rate < 40:
            return "CRITICAL"
        if consec_losses >= 3 or win_rate < 45 or profit_factor < 1.0:
            return "HIGH"
        if win_rate < 50 or profit_factor < 1.2:
            return "MEDIUM"
        return "LOW"

    def assess_profit_potential(self, perf: Dict[str, Any]) -> str:
        """Đánh giá tiềm năng lợi nhuận."""
        win_rate = float(perf.get("win_rate", 0))
        profit_factor = float(perf.get("profit_factor", 0))

        if win_rate >= 60 and profit_factor >= 2.0:
            return "EXCELLENT"
        if win_rate >= 55 and profit_factor >= 1.5:
            return "GOOD"
        if win_rate >= 50 and profit_factor >= 1.2:
            return "MODERATE"
        return "LOW"

    # ------------------------------------------------------------------
    # AI INTEGRATION
    # ------------------------------------------------------------------
    def get_ai_recommendations(self) -> Optional[Dict[str, Any]]:
        """Nhận khuyến nghị từ OpenAI."""
        perf_data = self.load_json(self.performance_file)
        analysis = self.analyze_performance()

        if not perf_data or not analysis:
            print("❌ Cannot load performance data")
            return None

        prompt = self.prepare_ai_prompt(perf_data, analysis)

        try:
            response = self.client.responses.create(
                model="gpt-4.1-mini",
                max_output_tokens=800,
                temperature=0.3,
                input=[
                    {
                        "role": "system",
                        "content": (
                            "Bạn là một protrader XAUUSD M1 với 10 năm kinh nghiệm. "
                            "Hãy ưu tiên tối đa hóa lợi nhuận nhưng vẫn kiểm soát rủi ro."
                        ),
                    },
                    {"role": "user", "content": prompt},
                ],
                response_format={"type": "json_object"},
            )

            ai_response = response.output_text
            recommendations = self.extract_json_from_response(ai_response)

            if recommendations:
                validated = self.validate_recommendations(recommendations)
                self.save_json(self.recommendations_file, validated)

                print("✅ AI Recommendations generated successfully")
                return validated

            print("⚠️  Could not parse AI response")
            return None

        except Exception as e:  # pylint: disable=broad-except
            print(f"❌ Error getting AI recommendations: {e}")
            return None

    def prepare_ai_prompt(self, perf_data: Dict[str, Any], analysis: Dict[str, Any]) -> str:
        """Chuẩn bị prompt cho AI."""
        daily = perf_data.get("daily_performance", {})
        current = perf_data.get("current_settings", {})

        prompt = f"""You are an expert XAUUSD M1 scalping risk manager. Your PRIMARY goal is PROFIT MAXIMIZATION while protecting capital.

CURRENT PERFORMANCE:
- Win Rate: {daily.get('win_rate', 0)}%
- Total Trades: {daily.get('total_trades', 0)}
- Winning: {daily.get('winning_trades', 0)} | Losing: {daily.get('losing_trades', 0)}
- Consecutive Losses: {daily.get('consecutive_losses', 0)}
- Daily Profit: ${daily.get('daily_profit', 0)}
- Profit Factor: {daily.get('profit_factor', 0)}
- Daily Drawdown: {daily.get('daily_drawdown_percent', 0)}%
- Risk Lock Active: {daily.get('risk_lock_active', False)}
- ATR({analysis['current_settings'].get('atr_period', 'n/a')}): {daily.get('atr_pips', 0)} pips
- Session Status: {daily.get('session_status', 'UNKNOWN')}

CURRENT SETTINGS:
- Stop Loss: {current.get('stop_loss_pips', 5)} pips
- Take Profit: {current.get('take_profit_pips', 8)} pips
- Risk Multiplier: {current.get('risk_multiplier', 1.0)}
- BreakEven Trigger: {current.get('break_even_trigger_pips', 'EA-managed')} pips

ANALYSIS:
- Health Score: {analysis['overall_health']}/100
- Risk Level: {analysis['risk_level']}
- Profit Potential: {analysis['profit_potential']}

DECISION RULES:
1. If consecutive losses >= 4 OR win rate < 40%: Disable trading
2. If profit factor < 1.0: Increase TP significantly or reduce SL
3. If win rate < 45%: Reduce risk multiplier to 0.5-0.7
4. If win rate > 60% AND profit factor > 1.5: Can increase risk to 1.2-1.3
5. If health score < 40: Disable trading temporarily
6. Prioritize PROFIT optimization over safety when metrics are good
7. If daily drawdown exceeds 80% of max allowed: keep trading disabled until reset

CONSTRAINTS:
- Stop Loss: 3-10 pips
- Take Profit: 5-15 pips (must be >= SL * 1.2)
- Risk Multiplier: 0.5-1.5

Respond with ONLY valid JSON (no markdown, no explanation):
{{
  "trading_enabled": true/false,
  "stop_loss_pips": number,
  "take_profit_pips": number,
  "risk_multiplier": number,
  "reasoning": "brief explanation"
}}"""

        return prompt

    def extract_json_from_response(self, response: str) -> Optional[Dict[str, Any]]:
        """Extract JSON from AI response."""
        try:
            return json.loads(response)
        except json.JSONDecodeError:
            start = response.find("{")
            end = response.rfind("}")
            if start >= 0 and end > start:
                json_str = response[start : end + 1]
                try:
                    return json.loads(json_str)
                except json.JSONDecodeError:
                    return None
        return None

    def validate_recommendations(self, recommendations: Dict[str, Any]) -> Dict[str, Any]:
        """Validate và điều chỉnh recommendations."""
        validated = recommendations.copy()

        sl = max(3, min(10, float(validated.get("stop_loss_pips", 5))))
        validated["stop_loss_pips"] = round(sl, 2)

        tp = max(5, min(15, float(validated.get("take_profit_pips", 8))))
        if tp < sl * 1.2:
            tp = round(sl * 1.5, 2)
        validated["take_profit_pips"] = round(tp, 2)

        risk_mult = max(0.5, min(1.5, float(validated.get("risk_multiplier", 1.0))))
        validated["risk_multiplier"] = round(risk_mult, 2)

        validated["trading_enabled"] = bool(validated.get("trading_enabled", True))
        validated["timestamp"] = datetime.now().isoformat()
        validated["validation_status"] = "passed"

        return validated

    # ------------------------------------------------------------------
    # REPORTING
    # ------------------------------------------------------------------
    def generate_report(self) -> Optional[Dict[str, Any]]:
        """Tạo báo cáo chi tiết."""
        analysis = self.load_json(self.ai_analysis_file)
        if not analysis:
            analysis = self.analyze_performance()

        recommendations = self.load_json(self.recommendations_file)

        if not analysis:
            print("❌ Cannot generate report - no analysis data")
            return None

        report = {
            "report_date": datetime.now().isoformat(),
            "analysis_summary": {
                "health_score": analysis["overall_health"],
                "risk_level": analysis["risk_level"],
                "profit_potential": analysis["profit_potential"],
            },
            "key_findings": [],
            "ai_recommendations": recommendations or {},
            "implementation_priority": [],
        }

        if analysis["risk_level"] in ["CRITICAL", "HIGH"]:
            report["key_findings"].append(
                {
                    "type": "WARNING",
                    "message": f"Risk level is {analysis['risk_level']}. Immediate action required.",
                }
            )

        if analysis["overall_health"] < 50:
            report["key_findings"].append(
                {
                    "type": "ALERT",
                    "message": f"Health score is low ({analysis['overall_health']}/100).",
                }
            )

        if recommendations:
            if not recommendations.get("trading_enabled", True):
                report["implementation_priority"].append(
                    {
                        "priority": 1,
                        "action": "STOP TRADING",
                        "reason": "AI recommends pausing due to risk levels",
                    }
                )

            report["implementation_priority"].append(
                {
                    "priority": 2,
                    "action": (
                        "Adjust SL/TP to "
                        f"{recommendations.get('stop_loss_pips')}/"
                        f"{recommendations.get('take_profit_pips')} pips"
                    ),
                    "reason": "Optimize risk-reward ratio",
                }
            )

        report_file = f"AI_Report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        self.save_json(report_file, report)

        print(f"📊 Report generated: {report_file}")
        return report

    # ------------------------------------------------------------------
    # WORKFLOW
    # ------------------------------------------------------------------
    def run_full_analysis(self) -> Optional[Dict[str, Any]]:
        """Chạy phân tích đầy đủ."""
        print("=" * 60)
        print("🤖 AI TRADING OPTIMIZER - OPENAI POWERED")
        print("=" * 60)

        print("\n📈 Step 1: Analyzing performance data...")
        analysis = self.analyze_performance()

        if analysis:
            print(f"   ✓ Health Score: {analysis['overall_health']}/100")
            print(f"   ✓ Risk Level: {analysis['risk_level']}")
            print(f"   ✓ Profit Potential: {analysis['profit_potential']}")
        else:
            print("   ❌ No performance data available")
            return None

        print("\n🧠 Step 2: Consulting OpenAI...")
        recommendations = self.get_ai_recommendations()

        if recommendations:
            print(f"   ✓ Trading Enabled: {recommendations.get('trading_enabled')}")
            print(
                "   ✓ SL/TP: "
                f"{recommendations.get('stop_loss_pips')}/"
                f"{recommendations.get('take_profit_pips')} pips"
            )
            print(f"   ✓ Risk Multiplier: {recommendations.get('risk_multiplier')}")
        else:
            print("   ⚠️  Could not get AI recommendations")

        print("\n📊 Step 3: Generating report...")
        report = self.generate_report()

        print("\n" + "=" * 60)
        print("✅ ANALYSIS COMPLETE")
        print("=" * 60)

        if recommendations:
            print(f"\n💡 AI Reasoning:\n{recommendations.get('reasoning', 'N/A')}")

        return {
            "analysis": analysis,
            "recommendations": recommendations,
            "report": report,
        }


def main() -> None:
    """Main execution."""
    api_key = os.getenv("OPENAI_API_KEY", "your-openai-api-key-here")

    if api_key == "your-openai-api-key-here":
        print("⚠️  Please set OPENAI_API_KEY environment variable")
        print("   Windows: setx OPENAI_API_KEY \"your-key-here\"")
        print("   Linux/Mac: export OPENAI_API_KEY=\"your-key-here\"")
        return

    optimizer = AITradingOptimizer(api_key)
    results = optimizer.run_full_analysis()

    if results and results.get("recommendations"):
        recs = results["recommendations"]

        print("\n" + "=" * 60)
        print("📋 IMPLEMENTATION INSTRUCTIONS")
        print("=" * 60)
        print(
            f"\n1. Set EA parameter 'InitialSL_Pips' to: {recs.get('stop_loss_pips')}"
        )
        print(
            f"2. Set EA parameter 'InitialTP_Pips' to: {recs.get('take_profit_pips')}"
        )
        print(
            f"3. Risk multiplier will auto-adjust to: {recs.get('risk_multiplier')}"
        )

        if not recs.get("trading_enabled"):
            print("\n⚠️  WARNING: AI recommends DISABLING trading!")
            print("   Remove EA from chart or wait for better conditions")


if __name__ == "__main__":
    main()
