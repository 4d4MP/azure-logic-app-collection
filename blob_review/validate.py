#!/usr/bin/env python3
"""blob-review — offline validation of the playbook JSON.

    ./validate.py            check playbook/workflow.json + playbook/azuredeploy.json
    ./validate.py --quiet    print only failures

Every check here exists because a real deployment was rejected by it. Azure
reports one such error per attempt, and each attempt is a round trip, so it is
much cheaper to fail here. Exits non-zero on any problem.

  1. drift        the two files must carry an identical definition
  2. static       no @expression in a typed part of the workflow schema
  3. refs         every outputs()/body()/actions()/result() reference must name
                  an action on the referring action's runAfter path
  4. rules        the three Logic Apps rules that rejected earlier deployments
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WF = os.path.join(HERE, 'playbook', 'workflow.json')
ARM = os.path.join(HERE, 'playbook', 'azuredeploy.json')

REF = re.compile(r"\b(?:outputs|body|actions|result)\('([^']+)'\)")
# Deserialized at deploy time rather than evaluated at runtime, so an
# expression in any of these fails with "Could not convert string to ...".
TYPED = {'runtimeConfiguration', 'recurrence', 'limit'}

problems = []
notes = []


def fail(msg):
    problems.append(msg)


def definition(doc):
    if 'definition' in doc:
        return doc['definition']
    return [r for r in doc['resources']
            if r['type'] == 'Microsoft.Logic/workflows'][0]['properties']['definition']


def walk_typed(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            walk_typed(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk_typed(v, path + (str(i),))
    elif isinstance(node, str) and node.startswith('@') and TYPED & set(path):
        fail("static: %s is an expression in a typed part of the schema (%s)"
             % ('.'.join(path), node))


def walk_refs(actions, inherited, path='root'):
    """An action may only reference actions on its own runAfter path, or ones
    reachable from the scope that contains it."""
    anc = {}

    def resolve(name, seen):
        if name in anc:
            return anc[name]
        if name in seen:
            fail("refs: runAfter cycle through '%s'" % name)
            return set()
        out = set()
        for parent in actions.get(name, {}).get('runAfter', {}) or {}:
            if parent not in actions:
                fail("refs: %s/%s runAfter names '%s', which is not in this scope"
                     % (path, name, parent))
                continue
            out.add(parent)
            out |= resolve(parent, seen | {name})
        anc[name] = out
        return out

    for name in actions:
        resolve(name, set())

    for name, action in actions.items():
        allowed = anc[name] | inherited
        own = {k: v for k, v in action.items() if k not in ('actions', 'else')}
        for ref in sorted(set(REF.findall(json.dumps(own)))):
            if ref == name or ref in allowed:
                continue
            fail("refs: %s/%s references '%s', which is not on its runAfter path"
                 % (path, name, ref))
        children = dict(action.get('actions') or {})
        children.update((action.get('else') or {}).get('actions') or {})
        if children:
            walk_refs(children, allowed | {name}, '%s/%s' % (path, name))


def walk_rules(d):
    triggers = d.get('triggers', {})
    recurring = [n for n, t in triggers.items() if 'recurrence' in t]
    concurrent = [n for n, t in triggers.items() if 'runtimeConfiguration' in t]

    # Only a single trigger with concurrency control is supported, and no other
    # triggers can be defined.
    if concurrent and len(triggers) > 1:
        fail("rules: trigger(s) %s carry a concurrency control, which is not "
             "allowed alongside a second trigger" % ', '.join(concurrent))

    # A workflow with a Response action may not have a recurrence trigger. The
    # check is static: gating the Response behind a condition does not help.
    blob = json.dumps(d['actions'])
    if recurring and '"Response"' in blob:
        fail("rules: a Response action cannot coexist with the recurrence "
             "trigger(s) %s" % ', '.join(recurring))

    if len(triggers) > 10:
        fail("rules: %d triggers; a Consumption workflow allows at most 10"
             % len(triggers))

    # One action per loop iteration keeps ~30,000 addresses under the 100,000
    # action executions per 5 minutes that Consumption allows.
    for name, a in [(n, a) for n, a in walk_all(d['actions'])]:
        if a.get('type') == 'Foreach':
            n = len(a.get('actions') or {})
            reps = ((a.get('runtimeConfiguration') or {}).get('concurrency') or {}).get('repetitions')
            if n > 1:
                notes.append("%s has %d actions per iteration; at ~30,000 items "
                             "that is %d executions against a 100,000 / 5 min limit"
                             % (name, n, n * 30000))
            if reps is None:
                notes.append("%s has no concurrency setting; it will default to 20" % name)


def walk_all(actions):
    for name, a in actions.items():
        yield name, a
        for kids in (a.get('actions') or {}, (a.get('else') or {}).get('actions') or {}):
            for pair in walk_all(kids):
                yield pair


def main():
    quiet = '--quiet' in sys.argv
    wf, arm = json.load(open(WF)), json.load(open(ARM))
    dwf, darm = definition(wf), definition(arm)

    for key in ('triggers', 'actions'):
        if dwf[key] != darm[key]:
            fail("drift: definition %s differ between workflow.json and azuredeploy.json" % key)

    for label, d in (('workflow.json', dwf), ('azuredeploy.json', darm)):
        walk_typed(d.get('triggers', {}), (label, 'triggers'))
        walk_typed(d['actions'], (label, 'actions'))
        walk_refs(d['actions'], set(d.get('triggers', {})), label)
        walk_rules(d)

    # Referencing a definition parameter that does not exist fails at runtime,
    # not at deploy time, which is the worst of both.
    declared = set(dwf.get('parameters', {}))
    used = set(re.findall(r"parameters\('([^']+)'\)", json.dumps([dwf['triggers'], dwf['actions']])))
    for missing in sorted(used - declared):
        fail("params: the definition references parameters('%s'), which is not declared" % missing)
    for unused in sorted(declared - used - {'$connections'}):
        notes.append("definition parameter '%s' is declared but never referenced" % unused)

    if not quiet:
        for n in sorted(set(notes)):
            print("  note: %s" % n)
    for p in problems:
        print("  FAIL: %s" % p)
    print("%s: %d problem(s)" % (os.path.basename(HERE), len(problems)))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
