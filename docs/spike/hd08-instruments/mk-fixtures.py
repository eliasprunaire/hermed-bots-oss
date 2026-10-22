#!/usr/bin/env python3
"""mk-fixtures.py <dossier-de-sortie> : les variantes de fixture des lanes de HD-08, tirées de hermes-current/contract.json
Chaque variante est un dossier <sortie>/<nom>/hermes-current/contract.json que hv-fake-hermes.py lit par --fixtures
  empty  aucun profil : la table n'a que son en-tête (lane 5)
  long   un nom de 300 caractères, un nom emoji, un nom de droite à gauche, et hv-bot-a (lane 6)
  added  la fixture de base plus le profil actif hv-new : le serveur que la lane 7 met en place en cours de route
  perf   les neuf profils actifs du PRD et 200 fils par bot (perf)"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "..", "..", "..", ".cursor", "skills", "verify-hermed-bots", "fixtures", "hermes-current", "contract.json")
HEADER = (
    "\n Profile          Model                        Gateway      Alias        Distribution\n"
    " ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────\n"
)
PRD = ["default", "cyber", "gaming", "ia", "perso", "recherches", "sport", "tiny", "wikilibriste"]


def row(name, gateway="running"):
    return "  %s   hv-fake-1                    %s      —            —\n" % (name, gateway)


def table(names):
    return HEADER + "".join(row(n) for n in names) + "\n"


def write(out, name, mutate):
    contract = copy.deepcopy(json.load(open(BASE, encoding="utf-8")))
    mutate(contract)
    folder = os.path.join(out, name, "hermes-current")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "contract.json"), "w", encoding="utf-8") as handle:
        json.dump(contract, handle, ensure_ascii=False, indent=2)
    print("fixture %s -> %s" % (name, folder))


def empty(c):
    c["contracts"]["list_profiles"]["output"] = table([])
    c["profiles"]["served"] = []


def long_names(c):
    names = ["default", "long-" + "n" * 295, "🤖-bot-🚀", "مرحبا-بوت", "hv-bot-a"]
    assert len(names[1]) == 300
    c["contracts"]["list_profiles"]["output"] = table(names)
    c["profiles"]["served"] = names


def added(c):
    c["contracts"]["list_profiles"]["output"] = c["contracts"]["list_profiles"]["output"].replace(
        "  hv-old ", "  hv-new           hv-fake-1                    running      —            —\n  hv-old ", 1
    )
    assert "hv-new" in c["contracts"]["list_profiles"]["output"]
    c["profiles"]["served"] = c["profiles"]["served"] + ["hv-new"]


def perf(c):
    c["contracts"]["list_profiles"]["output"] = table(PRD)
    c["profiles"]["served"] = PRD
    sessions = c["contracts"]["list_sessions"]["response"]
    template = sessions["data"][0]
    data = []
    for i in range(1, 201):
        entry = copy.deepcopy(template)
        entry.update(id="s-t-%03d" % i, title="Fil perf %03d" % i, last_active=template["last_active"] - i)
        data.append(entry)
    sessions["data"] = data
    sessions["limit"] = 200


if __name__ == "__main__":
    out = sys.argv[1]
    for name, mutate in (("empty", empty), ("long", long_names), ("added", added), ("perf", perf)):
        write(out, name, mutate)
