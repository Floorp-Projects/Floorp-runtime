# Any copyright is dedicated to the Public Domain.
# http://creativecommons.org/publicdomain/zero/1.0/

import fluent.syntax.ast as FTL
from fluent.migrate.helpers import VARIABLE_REFERENCE
from fluent.migrate.transforms import CONCAT, REPLACE


def migrate(ctx):
    """Bug 2023800 - Migrate HTTP error message, part {index}"""
    path = "toolkit/toolkit/neterror/netError.ftl"
    ctx.add_transforms(
        path,
        path,
        [
            FTL.Message(
                id=FTL.Identifier("fp-neterror-http-error-page-intro"),
                value=REPLACE(
                    "dom/chrome/appstrings.properties",
                    "httpErrorPage",
                    {
                        "%1$S": CONCAT(
                            FTL.TextElement("<strong>"),
                            VARIABLE_REFERENCE("hostname"),
                            FTL.TextElement("</strong>"),
                        ),
                    },
                    normalize_printf=True,
                ),
            ),
        ],
    )
